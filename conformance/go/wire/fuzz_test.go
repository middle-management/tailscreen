package wire

import (
	"bytes"
	"encoding/binary"
	"testing"
)

// Coverage-guided fuzzing of every parser this package implements.
//
// The vectors next door say what a correct implementation does with input
// somebody meant to send. These say what it does with input nobody meant to
// send — which is the input that actually arrives, because TS-GEN-011 puts a
// tunnel around the traffic but nothing around the peer, and every parser
// here reads bytes an admitted-or-not peer chose (TS-SEC-002, TS-SEC-008).
//
// The assertions are structural invariants rather than expected values: a
// fuzzer cannot know what a random datagram should decode to, but it can
// know that a successful decode never claims more bytes than it was given,
// that a rejection stays rejected, and that anything the encoder produces
// the decoder reads back. Those are the properties whose violation is a
// memory-safety bug or an interop bug, and they are checkable without a
// second implementation.
//
// The seed corpus runs on every `go test`, so these cost CI nothing. Real
// fuzzing is opt-in and time-boxed:
//
//	cd conformance/go && go test ./wire -run '^$' -fuzz FuzzDecodeFEC -fuzztime 60s
//	make fuzz-conformance                     # every target, 30s each
//
// A crash is written to testdata/fuzz/<Target>/ — commit it, it becomes a
// permanent regression case.

// seedDatagrams are well-formed messages of every kind, so the fuzzer starts
// from valid input and mutates outward rather than spending its budget
// discovering that byte 0 means something.
func seedDatagrams() [][]byte {
	report := Report{
		FracLostQ8: 13, ExtHighestSeq: 70000, JitterTicks: 900,
		LastPingTs: 1234567890123456789, DelaySincePingMs: 17,
		FECRecovered: 5, NACKRecovered: 9,
	}
	caps := byte(CapNACK | CapReceiverReport | CapFEC)
	return [][]byte{
		{},
		EncodeControl(Hello),
		EncodeControl(PLI),
		EncodeHello(caps),
		EncodeHelloAck(2, nil),
		EncodeHelloAck(2, &caps),
		EncodeNACK([]NACKEntry{{PID: 1000, BLP: 0x0005}}),
		EncodeNACK([]NACKEntry{{PID: 1, BLP: 0}, {PID: 65535, BLP: 0xFFFF}}),
		EncodeReport(report, false),
		EncodeReport(report, true),
		EncodePing(1234567890123456789),
		EncodeFEC(1000, 3, bytes.Repeat([]byte{0xA5}, 40)),
		EncodeRTPHeader(RTPHeader{PayloadType: PTH264, Sequence: 7, Timestamp: 90000, SSRC: 42}),
	}
}

func addSeeds(f *testing.F) {
	for _, seed := range seedDatagrams() {
		f.Add(seed)
	}
}

// FuzzDecodeControl covers the demultiplex every inbound datagram passes
// through first (TS-GEN-020, TS-CTL-002).
func FuzzDecodeControl(f *testing.F) {
	addSeeds(f)
	f.Fuzz(func(t *testing.T, data []byte) {
		class := Classify(data)
		if len(data) == 0 && class != ClassEmpty {
			t.Fatalf("an empty datagram classified as %v", class)
		}
		kind, ok := DecodeControl(data)
		if !ok {
			return
		}
		if class != ClassControl {
			t.Fatalf("%#x decoded as control message %v but classified as %v", data[0], kind, class)
		}
		if byte(kind) != data[0] {
			t.Fatalf("decoded %v from a datagram whose first byte is %#x", kind, data[0])
		}
		if name, known := ControlName(kind); !known {
			t.Fatalf("decoded an unnamed control kind %#x", byte(kind))
		} else if back, found := ControlByName(name); !found || back != kind {
			t.Fatalf("%v does not round-trip through its name %q", kind, name)
		}
	})
}

// FuzzDecodeHelloAck pins the compatibility rule the extended acknowledgement
// rests on: the strict parser accepts exactly the five-byte form and nothing
// else, and the tolerant one accepts whatever the strict one does
// (TS-CAP-004, TS-CAP-005).
func FuzzDecodeHelloAck(f *testing.F) {
	addSeeds(f)
	f.Fuzz(func(t *testing.T, data []byte) {
		strictSSRC, strictOK := DecodeHelloAckStrict(data)
		tolerantSSRC, _, tolerantOK := DecodeHelloAckTolerant(data)

		if strictOK && len(data) != 5 {
			t.Fatalf("the strict parser accepted %d bytes; it must accept only 5", len(data))
		}
		if strictOK && !tolerantOK {
			t.Fatal("the tolerant parser rejected an acknowledgement the strict parser accepted")
		}
		if strictOK && strictSSRC != tolerantSSRC {
			t.Fatalf("the two parsers disagree about the SSRC: %d vs %d", strictSSRC, tolerantSSRC)
		}
		if tolerantOK && len(data) < 5 {
			t.Fatalf("the tolerant parser accepted %d bytes", len(data))
		}
	})
}

// FuzzDecodeNACK pins the all-or-nothing rule: a truncated entry list yields
// no entries rather than the prefix that happens to have arrived
// (TS-NCK-002).
func FuzzDecodeNACK(f *testing.F) {
	addSeeds(f)
	f.Fuzz(func(t *testing.T, data []byte) {
		entries := DecodeNACK(data)
		if len(entries) == 0 {
			return
		}
		if len(data) < 2+4*len(entries) {
			t.Fatalf("decoded %d entries out of %d bytes", len(entries), len(data))
		}
		if len(entries) != int(data[1]) {
			t.Fatalf("decoded %d entries from a datagram declaring %d", len(entries), data[1])
		}
		// A datagram carrying at most the 16 entries an encoder may emit,
		// and no trailing bytes, must re-encode to itself.
		if len(entries) <= 16 && len(data) == 2+4*len(entries) {
			if got := EncodeNACK(entries); !bytes.Equal(got, data) {
				t.Fatalf("re-encoding changed the datagram:\n  in:  %x\n  out: %x", data, got)
			}
		}
	})
}

// FuzzDecodeReport pins the three permitted lengths and the read-absent-as-
// zero rule (TS-RRP-009).
func FuzzDecodeReport(f *testing.F) {
	addSeeds(f)
	f.Fuzz(func(t *testing.T, data []byte) {
		report, ok := DecodeReport(data)
		if !ok {
			return
		}
		if len(data) < 20 {
			t.Fatalf("accepted a %d-byte report", len(data))
		}
		if len(data) < 22 && report.FECRecovered != 0 {
			t.Fatal("a report too short to carry fecRecovered decoded a non-zero one")
		}
		if len(data) < 24 && report.NACKRecovered != 0 {
			t.Fatal("a report too short to carry nackRecovered decoded a non-zero one")
		}
		// Exactly the legacy or the extended layout must re-encode to itself;
		// a longer datagram carries trailing bytes we deliberately ignore.
		switch len(data) {
		case 20:
			if got := EncodeReport(report, false); !bytes.Equal(got, data) {
				t.Fatalf("the 20-byte form did not round-trip:\n  in:  %x\n  out: %x", data, got)
			}
		case 24:
			if got := EncodeReport(report, true); !bytes.Equal(got, data) {
				t.Fatalf("the 24-byte form did not round-trip:\n  in:  %x\n  out: %x", data, got)
			}
		}
	})
}

// FuzzDecodeFEC pins the bounds every field of a parity datagram is checked
// against before it reaches the solver (TS-FEC-001 … TS-FEC-003).
func FuzzDecodeFEC(f *testing.F) {
	addSeeds(f)
	f.Fuzz(func(t *testing.T, data []byte) {
		baseSeq, count, body, ok := DecodeFEC(data)
		if !ok {
			return
		}
		if count < FECMinGroupSize || count > FECMaxGroupSize {
			t.Fatalf("accepted a group size of %d", count)
		}
		if len(body) < FECMinBodyBytes || len(body) > FECMaxBodyBytes {
			t.Fatalf("accepted a %d-byte parity body", len(body))
		}
		if got := EncodeFEC(baseSeq, count, body); !bytes.Equal(got, data) {
			t.Fatalf("the datagram did not round-trip:\n  in:  %x\n  out: %x", data, got)
		}
	})
}

// FuzzRecover is the one that matters most for memory safety: `Recover`
// reads a length out of attacker-influenced parity and cuts a buffer to it
// (TS-FEC-010). Whatever it returns must be a whole RTP packet or nothing.
func FuzzRecover(f *testing.F) {
	f.Add([]byte{0x00, 0x20, 0x60, 0x00, 0x00, 0x01, 0x00, 0xAA, 0xBB}, []byte{}, uint16(500), uint32(42))
	f.Add(bytes.Repeat([]byte{0x11}, 40), bytes.Repeat([]byte{0x80}, 20), uint16(0), uint32(0))
	f.Fuzz(func(t *testing.T, body, member []byte, missingSeq uint16, ssrc uint32) {
		var members [][]byte
		if len(member) > 0 {
			members = [][]byte{member}
		}
		packet := Recover(missingSeq, ssrc, members, body)
		if packet == nil {
			return
		}
		if len(packet) < RTPHeaderSize {
			t.Fatalf("recovered a %d-byte packet, shorter than an RTP header", len(packet))
		}
		if len(packet)-RTPHeaderSize > len(body)-FECPrefixBytes {
			t.Fatalf("recovered %d payload bytes out of a %d-byte parity body",
				len(packet)-RTPHeaderSize, len(body))
		}
		if packet[0] != 0x80 {
			t.Fatalf("recovered a packet whose first byte is %#x, not 0x80", packet[0])
		}
		if got := binary.BigEndian.Uint16(packet[2:4]); got != missingSeq {
			t.Fatalf("recovered sequence %d, asked for %d", got, missingSeq)
		}
		if got := binary.BigEndian.Uint32(packet[8:12]); got != ssrc {
			t.Fatalf("recovered SSRC %d, asked for %d", got, ssrc)
		}
	})
}

// FuzzParityRoundTrip is the structured half: build a real group, take the
// parity, drop one member, and require the drop to come back byte for byte
// (TS-FEC-009). Recovery that merely fails to crash is not recovery.
func FuzzParityRoundTrip(f *testing.F) {
	f.Add(uint8(3), uint16(40), uint16(64), uint16(12), uint8(0))
	f.Add(uint8(2), uint16(0), uint16(1100), uint16(0), uint8(1))
	f.Fuzz(func(t *testing.T, rawCount uint8, lenA, lenB, lenC uint16, dropIndex uint8) {
		count := int(rawCount%3) + 2 // 2…4 members
		lengths := []int{int(lenA % 1101), int(lenB % 1101), int(lenC % 1101), 33}

		group := make([][]byte, 0, count)
		for i := 0; i < count; i++ {
			payload := make([]byte, lengths[i])
			for j := range payload {
				payload[j] = byte(i*31 + j*7 + 3)
			}
			header := RTPHeader{
				Marker:      i == count-1,
				PayloadType: PTH264,
				Sequence:    uint16(500 + i),
				Timestamp:   90000,
				SSRC:        42,
			}
			group = append(group, append(EncodeRTPHeader(header), payload...))
		}

		body := ParityBody(group)
		if body == nil {
			t.Fatalf("a %d-member group produced no parity", count)
		}

		drop := int(dropIndex) % count
		members := make([][]byte, 0, count-1)
		for i, p := range group {
			if i != drop {
				members = append(members, p)
			}
		}

		recovered := Recover(uint16(500+drop), 42, members, body)
		if recovered == nil {
			t.Fatalf("failed to recover member %d of %d (lengths %v)", drop, count, lengths[:count])
		}
		if !bytes.Equal(recovered, group[drop]) {
			t.Fatalf("member %d came back changed:\n  want: %x\n  got:  %x", drop, group[drop], recovered)
		}
	})
}

// FuzzDecodeRTPHeader pins the offset arithmetic that skips a CSRC list and a
// header extension — the one place in this package where a peer's own numbers
// decide how far a reader advances (TS-VID-003).
func FuzzDecodeRTPHeader(f *testing.F) {
	addSeeds(f)
	f.Fuzz(func(t *testing.T, data []byte) {
		header, offset, ok := DecodeRTPHeader(data)
		if !ok {
			return
		}
		if offset < RTPHeaderSize {
			t.Fatalf("payload offset %d is inside the fixed header", offset)
		}
		if offset > len(data) {
			t.Fatalf("payload offset %d runs past the %d-byte datagram", offset, len(data))
		}
		if data[0]&0xC0 != 0x80 {
			t.Fatalf("accepted a datagram whose version bits are %#x", data[0]&0xC0)
		}
		if header.PayloadType > 127 {
			t.Fatalf("decoded payload type %d", header.PayloadType)
		}
		// The fixed header the parser read must be exactly the bytes it read
		// it from — but only for a header an ENCODER can express. The parser
		// accepts a padding bit nothing here emits (TS-VID-008), and a
		// round-trip cannot reproduce a field the encoder has no way to set.
		if offset == RTPHeaderSize && data[0] == 0x80 {
			if got := EncodeRTPHeader(header); !bytes.Equal(got, data[:RTPHeaderSize]) {
				t.Fatalf("the fixed header did not round-trip:\n  in:  %x\n  out: %x",
					data[:RTPHeaderSize], got)
			}
		}
	})
}

// FuzzFrameParser drives the TCP parser with arbitrary bytes delivered in
// arbitrary splits. Three properties, all of them things a peer can attack:
// the parser never yields more than it was given, an oversized declared
// length poisons the stream permanently, and a split changes nothing
// (TS-TCP-004 … TS-TCP-007).
func FuzzFrameParser(f *testing.F) {
	f.Add(EncodeFrame(MsgAnnotation, []byte(`{"type":"clearAll"}`)), uint8(3))
	f.Add(append(EncodeFrame(MsgControlRequest, nil), EncodeFrame(0xFF, []byte("skip me"))...), uint8(1))
	f.Add(append([]byte{byte(MsgAnnotation)}, 0xFF, 0xFF, 0xFF, 0xFF), uint8(0))
	f.Fuzz(func(t *testing.T, data []byte, chunkSize uint8) {
		split := int(chunkSize) + 1

		var chunked FrameParser
		var chunkedFrames []Frame
		for off := 0; off < len(data); off += split {
			end := off + split
			if end > len(data) {
				end = len(data)
			}
			chunked.Append(data[off:end])
			chunkedFrames = append(chunkedFrames, chunked.Drain()...)
		}

		var whole FrameParser
		whole.Append(data)
		wholeFrames := whole.Drain()

		if len(chunkedFrames) != len(wholeFrames) {
			t.Fatalf("splitting the stream into %d-byte chunks changed the frame count: %d vs %d",
				split, len(chunkedFrames), len(wholeFrames))
		}
		if chunked.Corrupt() != whole.Corrupt() {
			t.Fatalf("splitting the stream changed the corrupt verdict: %v vs %v",
				chunked.Corrupt(), whole.Corrupt())
		}

		total := 0
		for i, frame := range wholeFrames {
			if !IsKnownMessageType(frame.Type) {
				t.Fatalf("yielded a frame of unassigned type %#x", byte(frame.Type))
			}
			if !bytes.Equal(frame.Payload, chunkedFrames[i].Payload) {
				t.Fatalf("frame %d differs between the split and whole parses", i)
			}
			if len(frame.Payload) > MaxPayloadLength {
				t.Fatalf("yielded a %d-byte payload", len(frame.Payload))
			}
			total += FrameHeaderSize + len(frame.Payload)
		}
		if total > len(data) {
			t.Fatalf("yielded %d bytes of frames out of %d bytes of input", total, len(data))
		}

		// Poisoning is permanent: nothing parses after an oversized length,
		// however much well-formed traffic follows it.
		if whole.Corrupt() {
			whole.Append(EncodeFrame(MsgControlRequest, nil))
			if got := whole.Drain(); len(got) != 0 {
				t.Fatalf("a poisoned parser yielded %d frames", len(got))
			}
		}
	})
}

// FuzzDecodePayloads covers the JSON decoders. They are the parsers with the
// widest input surface — arbitrary text, arriving inside a frame from any
// peer that can dial the port — and one of them feeds the injector, so a
// coordinate it accepts is a coordinate somebody's cursor moves to
// (TS-RMT-029, TS-TCP-023).
func FuzzDecodePayloads(f *testing.F) {
	for _, seed := range []string{
		`{"mouseMove":{"x":0.5,"y":0.5}}`,
		`{"mouseDown":{"x":0.5,"y":0.5,"button":"left","modifiers":8}}`,
		`{"keyDown":{"key":4,"modifiers":2}}`,
		`{"scroll":{"x":0,"y":0,"deltaX":0,"deltaY":-3,"modifiers":0}}`,
		`{"type":"clearAll"}`,
		`{"type":"undo","id":"6C84FB90-12C4-11E1-840D-7B25C5EE775A"}`,
		`{"type":"add","annotation":{"id":"6C84FB90-12C4-11E1-840D-7B25C5EE775A","tool":"pen",` +
			`"points":[[0.25,0.5]],"color":{"r":1,"g":0,"b":0,"a":1},"width":3}}`,
		`{"fromHostname":"studio-imac"}`,
		`{"type":"acceptShare"}`,
		`{"reason":"stopped"}`,
		`{"version":"1.0","shareName":"Display 1","hostname":"box",` +
			`"screenResolution":{"width":1,"height":1},"isSharing":true,"timestamp":0}`,
	} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, payload []byte) {
		if event, err := DecodeInputEvent(payload); err == nil {
			switch event.Kind {
			case "mouseMove", "mouseDown", "mouseUp", "scroll", "keyDown", "keyUp":
			default:
				t.Fatalf("accepted an input event of kind %q", event.Kind)
			}
			if event.X != event.X || event.Y != event.Y {
				t.Fatal("accepted a NaN coordinate")
			}
			if event.Button != "" && !validButtons[event.Button] {
				t.Fatalf("accepted the button %q", event.Button)
			}
		}

		if op, err := DecodeAnnotationOp(payload); err == nil {
			switch op.Kind {
			case "add":
				if !validTools[op.Tool] {
					t.Fatalf("accepted the tool %q", op.Tool)
				}
			case "undo", "clearAll":
			default:
				t.Fatalf("accepted an annotation op of kind %q", op.Kind)
			}
		}

		if host, err := DecodeRequestToShare(payload); err == nil {
			if n := len([]rune(host)); n > MaxHostnameChars {
				t.Fatalf("returned a %d-character hostname unclamped", n)
			}
		}

		if n := len([]rune(DecodeControlRevoked(payload))); n > MaxReasonChars {
			t.Fatalf("returned a %d-character reason unclamped", n)
		}

		if md, err := DecodeMetadata(payload); err == nil {
			if n := len([]rune(md.ShareName)); n > MaxDisplayStringChars {
				t.Fatalf("returned a %d-character share name unclamped", n)
			}
			if n := len([]rune(md.Hostname)); n > MaxDisplayStringChars {
				t.Fatalf("returned a %d-character hostname unclamped", n)
			}
			if md.VideoCodec != nil && *md.VideoCodec != "h264" && *md.VideoCodec != "hevc" {
				t.Fatalf("accepted the codec %q", *md.VideoCodec)
			}
		}

		_, _ = DecodeShareResponse(payload)
	})
}

// FuzzPacketize drives the encoders rather than the parsers: an access unit
// arrives from a hardware encoder, and a NAL length nobody anticipated must
// still produce packets a receiver can reassemble (TS-VID-004, TS-VID-006,
// TS-VID-030).
func FuzzPacketize(f *testing.F) {
	f.Add([]byte{0x65, 0x01, 0x02}, uint16(1100), uint16(100), uint8(0))
	f.Add([]byte{0x65}, uint16(2500), uint16(65534), uint8(1))
	f.Fuzz(func(t *testing.T, prefix []byte, extra, startSeq uint16, codec uint8) {
		nal := append(append([]byte{}, prefix...), make([]byte, int(extra%4096))...)
		hevc := codec%2 == 1

		var packets [][]byte
		if hevc {
			packets = PacketizeHEVC([][]byte{nal}, 90000, 42, startSeq)
		} else {
			packets = PacketizeH264([][]byte{nal}, 90000, 42, startSeq)
		}
		if len(packets) == 0 {
			return
		}

		for i, p := range packets {
			if len(p) < RTPHeaderSize {
				t.Fatalf("packet %d is shorter than an RTP header", i)
			}
			if len(p)-RTPHeaderSize > MaxRTPPayload {
				t.Fatalf("packet %d carries %d payload bytes, past the %d-byte limit",
					i, len(p)-RTPHeaderSize, MaxRTPPayload)
			}
			if got := binary.BigEndian.Uint16(p[2:4]); got != startSeq+uint16(i) {
				t.Fatalf("packet %d carries sequence %d, expected %d", i, got, startSeq+uint16(i))
			}
			marker := p[1]&0x80 != 0
			if marker != (i == len(packets)-1) {
				t.Fatalf("packet %d of %d has marker=%v", i, len(packets), marker)
			}
		}
	})
}
