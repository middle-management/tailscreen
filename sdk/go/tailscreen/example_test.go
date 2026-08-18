package tailscreen_test

import (
	"fmt"

	"github.com/middle-management/tailscreen/sdk/go/tailscreen"
)

// A viewer announces itself with the capabilities it implements, and reads
// back the SSRC it has been assigned along with the sharer's own.
func ExampleNegotiate() {
	local := tailscreen.CapNACK | tailscreen.CapReceiverReport | tailscreen.CapFEC
	hello := tailscreen.EncodeHello(local)

	// …the sharer answers. It advertises retransmission and parity, does not
	// implement receiver reports, and can inject remote input.
	remote := tailscreen.CapNACK | tailscreen.CapFEC | tailscreen.CapRemoteControl
	caps := remote
	ack := tailscreen.EncodeHelloAck(7, &caps)

	ssrc, serverCaps, ok := tailscreen.DecodeHelloAckTolerant(ack)
	if !ok {
		return
	}
	inPlay := tailscreen.Negotiate(local, serverCaps)

	fmt.Printf("hello:            %x\n", hello)
	fmt.Printf("ssrc:             %d\n", ssrc)
	fmt.Printf("retransmission:   %t\n", inPlay.Has(tailscreen.CapNACK))
	fmt.Printf("receiver reports: %t\n", inPlay.Has(tailscreen.CapReceiverReport))
	fmt.Printf("offer control:    %t\n", serverCaps.Has(tailscreen.CapRemoteControl))
	// Output:
	// hello:            0007
	// ssrc:             7
	// retransmission:   true
	// receiver reports: false
	// offer control:    true
}

// Every inbound datagram is demultiplexed by its first byte alone: there is
// no shim header and no second port (TS-GEN-020).
func ExampleClassify() {
	media := tailscreen.EncodeRTPHeader(tailscreen.RTPHeader{
		PayloadType: tailscreen.PTHEVC,
		Sequence:    7,
		Timestamp:   90000,
		SSRC:        42,
	})

	for _, datagram := range [][]byte{
		media,
		tailscreen.EncodeControl(tailscreen.PLI),
		{0x7F}, // assigned to nothing — discard it, do not error out
		{},
	} {
		switch tailscreen.Classify(datagram) {
		case tailscreen.ClassRTP:
			header, offset, _ := tailscreen.DecodeRTPHeader(datagram)
			fmt.Printf("rtp pt=%d payload starts at %d\n", header.PayloadType, offset)
		case tailscreen.ClassControl:
			if kind, ok := tailscreen.DecodeControl(datagram); ok {
				fmt.Printf("control %s\n", kind)
			} else {
				fmt.Println("control, unassigned — discarded")
			}
		case tailscreen.ClassEmpty:
			fmt.Println("empty — discarded")
		}
	}
	// Output:
	// rtp pt=97 payload starts at 12
	// control pli
	// control, unassigned — discarded
	// empty — discarded
}

// A NACK names missing sequence numbers as a first one plus a bitmask of the
// sixteen after it.
func ExampleNACKEntry_Missing() {
	entry := tailscreen.NACKEntry{PID: 1000, BLP: 0b101}
	fmt.Println(entry.Missing())

	datagram := tailscreen.EncodeNACK([]tailscreen.NACKEntry{entry})
	fmt.Printf("%x\n", datagram)
	// Output:
	// [1000 1001 1003]
	// 0a0103e80005
}

// One parity datagram repairs any single loss in its group with no round
// trip. Two losses in one group fall through to retransmission (TS-FEC-008).
func ExampleRecover() {
	var group [][]byte
	for i := 0; i < 3; i++ {
		header := tailscreen.EncodeRTPHeader(tailscreen.RTPHeader{
			Marker:      i == 2, // last packet of the access unit
			PayloadType: tailscreen.PTH264,
			Sequence:    uint16(500 + i),
			Timestamp:   90000,
			SSRC:        42,
		})
		group = append(group, append(header, byte(i), 0xAA, 0xBB))
	}

	body := tailscreen.ParityBody(group)
	parity := tailscreen.EncodeFEC(500, len(group), body)

	// The middle packet never arrives. The receiver knows which sequence
	// number is missing from its own gap tracking, and the SSRC from any
	// surviving member.
	baseSeq, _, recovered, ok := tailscreen.DecodeFEC(parity)
	if !ok {
		return
	}
	packet := tailscreen.Recover(baseSeq+1, 42, [][]byte{group[0], group[2]}, recovered)

	fmt.Printf("%x\n", packet)
	fmt.Println(string(mustEqual(packet, group[1])))
	// Output:
	// 806001f500015f900000002a01aabb
	// identical
}

func mustEqual(got, want []byte) []byte {
	if string(got) == string(want) {
		return []byte("identical")
	}
	return []byte("DIFFERENT")
}

// The TCP channel is length-framed. A parser must tolerate a frame split
// across segments, several frames in one segment, and message types it does
// not know (TS-TCP-003, TS-TCP-006, TS-TCP-007).
func ExampleFrameParser() {
	stream := append(
		tailscreen.EncodeFrame(tailscreen.MsgAnnotation, []byte(`{"type":"clearAll"}`)),
		tailscreen.EncodeFrame(0xFF, []byte("from a newer peer"))...,
	)
	stream = append(stream, tailscreen.EncodeFrame(tailscreen.MsgControlRequest, nil)...)

	var parser tailscreen.FrameParser
	for offset := 0; offset < len(stream); offset += 7 {
		end := offset + 7
		if end > len(stream) {
			end = len(stream)
		}
		parser.Append(stream[offset:end])
		for _, frame := range parser.Drain() {
			fmt.Printf("type %#02x payload %q\n", byte(frame.Type), frame.Payload)
		}
	}
	// Output:
	// type 0x03 payload "{\"type\":\"clearAll\"}"
	// type 0x06 payload ""
}
