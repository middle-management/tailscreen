// Package wire is a Go implementation of the Tailscreen wire protocol,
// written from docs/spec.md and from nothing else. It exists so the
// conformance vectors are checked by an implementation that shares no code
// with the Swift one: agreement between the two is evidence that the spec
// says what the vectors say.
//
// It implements the codecs, not the state machines — timers, admission
// policy and congestion control are normative but not vector-testable, and
// live in the spec's prose.
package wire

import "encoding/binary"

// Control message types — spec §4.1, Appendix A.1.
type ControlKind byte

const (
	Hello              ControlKind = 0x00
	Keepalive          ControlKind = 0x01
	Bye                ControlKind = 0x02
	PLI                ControlKind = 0x03
	HelloAck           ControlKind = 0x04
	ServerBye          ControlKind = 0x05
	HelloPending       ControlKind = 0x06
	CodecUnsupported   ControlKind = 0x07
	HelloDenied        ControlKind = 0x08
	ProfileUnsupported ControlKind = 0x09
	NACK               ControlKind = 0x0A
	ReceiverReport     ControlKind = 0x0B
	Ping               ControlKind = 0x0C
	FEC                ControlKind = 0x0D
)

// Capability bits — spec §5.1, Appendix A.3.
const (
	CapNACK           = 1 << 0
	CapReceiverReport = 1 << 1
	CapFEC            = 1 << 2
	CapRemoteControl  = 1 << 3
	CapAnnotations    = 1 << 4
)

var controlNames = map[ControlKind]string{
	Hello: "hello", Keepalive: "keepalive", Bye: "bye", PLI: "pli",
	HelloAck: "helloAck", ServerBye: "serverBye", HelloPending: "helloPending",
	CodecUnsupported: "codecUnsupported", HelloDenied: "helloDenied",
	ProfileUnsupported: "profileUnsupported", NACK: "nack",
	ReceiverReport: "receiverReport", Ping: "ping", FEC: "fec",
}

var controlByName = func() map[string]ControlKind {
	m := make(map[string]ControlKind, len(controlNames))
	for k, v := range controlNames {
		m[v] = k
	}
	return m
}()

// ControlName returns the spec name of a control byte, and whether the byte
// is assigned at all.
func ControlName(k ControlKind) (string, bool) {
	n, ok := controlNames[k]
	return n, ok
}

// ControlByName looks a control byte up by its spec name.
func ControlByName(name string) (ControlKind, bool) {
	k, ok := controlByName[name]
	return k, ok
}

// EncodeControl emits a bare one-byte control datagram (TS-CTL-001).
func EncodeControl(k ControlKind) []byte { return []byte{byte(k)} }

// DecodeControl reads the message type off a datagram. It reports false for
// an empty datagram (TS-GEN-022) and for an unassigned byte (TS-CTL-002);
// the caller MUST discard both silently.
func DecodeControl(b []byte) (ControlKind, bool) {
	if len(b) == 0 {
		return 0, false
	}
	k := ControlKind(b[0])
	if _, ok := controlNames[k]; !ok {
		return 0, false
	}
	return k, true
}

// DatagramClass is the result of the first-byte demultiplex (TS-GEN-020).
type DatagramClass int

const (
	ClassEmpty DatagramClass = iota
	ClassRTP
	ClassControl
)

// Classify demultiplexes an inbound UDP datagram by its first byte alone.
func Classify(b []byte) DatagramClass {
	if len(b) == 0 {
		return ClassEmpty
	}
	if b[0]&0xC0 == 0x80 {
		return ClassRTP
	}
	return ClassControl
}

// EncodeHello emits the extended two-byte HELLO. A viewer with no
// capabilities MAY send the one-byte form instead; both decode identically
// under DecodeHelloCaps (TS-CAP-006).
func EncodeHello(caps byte) []byte { return []byte{byte(Hello), caps} }

// DecodeHelloCaps reads the capability byte off a HELLO, returning 0 for the
// legacy one-byte form (TS-CAP-006) and for a datagram that is not a HELLO.
func DecodeHelloCaps(b []byte) byte {
	if len(b) < 2 || b[0] != byte(Hello) {
		return 0
	}
	return b[1]
}

// EncodeHelloAck emits the plain five-byte acknowledgement when caps is nil,
// and the extended six-byte form otherwise. TS-CAP-004: the extended form is
// for viewers that advertised capabilities, and for nobody else.
func EncodeHelloAck(ssrc uint32, caps *byte) []byte {
	out := make([]byte, 5, 6)
	out[0] = byte(HelloAck)
	binary.BigEndian.PutUint32(out[1:], ssrc)
	if caps != nil {
		out = append(out, *caps)
	}
	return out
}

// DecodeHelloAckStrict is the parser of an implementation that predates
// capability negotiation: it accepts exactly five bytes and rejects the
// extended form (TS-CAP-004). It is here because the extended form's
// backward compatibility depends on this parser rejecting it.
func DecodeHelloAckStrict(b []byte) (uint32, bool) {
	if len(b) != 5 || b[0] != byte(HelloAck) {
		return 0, false
	}
	return binary.BigEndian.Uint32(b[1:5]), true
}

// DecodeHelloAckTolerant is the capability-aware parser: it accepts both
// forms, reading absent capabilities as none (TS-CAP-005).
func DecodeHelloAckTolerant(b []byte) (ssrc uint32, caps byte, ok bool) {
	if len(b) < 5 || b[0] != byte(HelloAck) {
		return 0, 0, false
	}
	ssrc = binary.BigEndian.Uint32(b[1:5])
	if len(b) >= 6 {
		caps = b[5]
	}
	return ssrc, caps, true
}

// NACKEntry is one generic-NACK FCI entry: pid is the first missing sequence
// number, blp a bitmask of the 16 that follow it (spec §9.1).
type NACKEntry struct {
	PID uint16 `json:"pid"`
	BLP uint16 `json:"blp"`
}

// EncodeNACK emits a NACK, truncating to the 16-entry ceiling (TS-NCK-001).
func EncodeNACK(entries []NACKEntry) []byte {
	if len(entries) > 16 {
		entries = entries[:16]
	}
	out := make([]byte, 2, 2+4*len(entries))
	out[0] = byte(NACK)
	out[1] = byte(len(entries))
	for _, e := range entries {
		out = binary.BigEndian.AppendUint16(out, e.PID)
		out = binary.BigEndian.AppendUint16(out, e.BLP)
	}
	return out
}

// DecodeNACK parses a NACK. A truncated entry list yields no entries at all
// rather than the prefix that happens to have arrived (TS-NCK-002).
func DecodeNACK(b []byte) []NACKEntry {
	if len(b) < 2 || b[0] != byte(NACK) {
		return nil
	}
	count := int(b[1])
	if len(b) < 2+count*4 {
		return nil
	}
	out := make([]NACKEntry, 0, count)
	for i := 0; i < count; i++ {
		off := 2 + i*4
		out = append(out, NACKEntry{
			PID: binary.BigEndian.Uint16(b[off : off+2]),
			BLP: binary.BigEndian.Uint16(b[off+2 : off+4]),
		})
	}
	return out
}

// EncodePing emits the sharer's RTT probe (spec §9.2).
func EncodePing(serverUptimeNs uint64) []byte {
	out := make([]byte, 1, 9)
	out[0] = byte(Ping)
	return binary.BigEndian.AppendUint64(out, serverUptimeNs)
}

// DecodePing parses an RTT probe. Trailing bytes are ignored (TS-CTL-004).
func DecodePing(b []byte) (uint64, bool) {
	if len(b) < 9 || b[0] != byte(Ping) {
		return 0, false
	}
	return binary.BigEndian.Uint64(b[1:9]), true
}

// Report is a receiver report (spec §9.2).
type Report struct {
	FracLostQ8       uint8
	ExtHighestSeq    uint32
	JitterTicks      uint32
	LastPingTs       uint64
	DelaySincePingMs uint16
	FECRecovered     uint16
	NACKRecovered    uint16
}

// EncodeReport emits the 20-byte legacy form, or the 24-byte form when the
// link negotiated FEC (TS-RRP-011).
func EncodeReport(r Report, includeRecoveryFields bool) []byte {
	out := make([]byte, 2, 24)
	out[0] = byte(ReceiverReport)
	out[1] = r.FracLostQ8
	out = binary.BigEndian.AppendUint32(out, r.ExtHighestSeq)
	out = binary.BigEndian.AppendUint32(out, r.JitterTicks)
	out = binary.BigEndian.AppendUint64(out, r.LastPingTs)
	out = binary.BigEndian.AppendUint16(out, r.DelaySincePingMs)
	if includeRecoveryFields {
		out = binary.BigEndian.AppendUint16(out, r.FECRecovered)
		out = binary.BigEndian.AppendUint16(out, r.NACKRecovered)
	}
	return out
}

// DecodeReport parses any of the three permitted lengths, reading absent
// trailing counters as zero (TS-RRP-009).
func DecodeReport(b []byte) (Report, bool) {
	if len(b) < 20 || b[0] != byte(ReceiverReport) {
		return Report{}, false
	}
	r := Report{
		FracLostQ8:       b[1],
		ExtHighestSeq:    binary.BigEndian.Uint32(b[2:6]),
		JitterTicks:      binary.BigEndian.Uint32(b[6:10]),
		LastPingTs:       binary.BigEndian.Uint64(b[10:18]),
		DelaySincePingMs: binary.BigEndian.Uint16(b[18:20]),
	}
	if len(b) >= 22 {
		r.FECRecovered = binary.BigEndian.Uint16(b[20:22])
	}
	if len(b) >= 24 {
		r.NACKRecovered = binary.BigEndian.Uint16(b[22:24])
	}
	return r, true
}
