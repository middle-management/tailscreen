package tailscreen

import (
	"encoding/binary"
	"time"
)

// SpecVersion is the revision of docs/spec.md this package implements.
const SpecVersion = 1

// Port is the protocol's default port, used for TCP and UDP alike
// (TS-GEN-010).
//
// It is provisional: 7447 is not registered with IANA, and a registration
// could land on a different number (TS-GEN-016). Read the port from your own
// configuration and pass it around; do not write the literal at each listen,
// dial and probe site, which is what makes a renumbering a one-line change
// rather than an archaeology exercise.
const Port = 7447

// Timing constants from the specification's Appendix B. This package
// implements no timers — it exports the values so that yours agree with
// everyone else's.
const (
	// KeepaliveInterval is how often a viewer must announce itself
	// (TS-CTL-015).
	KeepaliveInterval = 500 * time.Millisecond
	// IdleTimeout is how long either end waits before tearing down a silent
	// session. The two ends use the SAME value by design (TS-CTL-016,
	// TS-CTL-017); do not tune one without the other.
	IdleTimeout = 15 * time.Second
	// PendingApprovalTimeout bounds how long a viewer may sit in a sharer's
	// approval queue (TS-ADM-003).
	PendingApprovalTimeout = 60 * time.Second
	// ExpelledQuietWindow is how long an expelled address is answered with
	// denial rather than re-admitted (TS-ADM-008).
	ExpelledQuietWindow = 30 * time.Second
	// ReceiverReportInterval is the nominal cadence of receiver reports and
	// of the RTT pings they echo (TS-RRP-001, TS-RRP-005).
	ReceiverReportInterval = time.Second
	// FECParityIdle is how long a receiver waits without parity before
	// disarming its FEC machinery (TS-FEC-013).
	FECParityIdle = 3 * time.Second
	// ReorderGapHold is the minimum time a receiver using selective
	// retransmission holds an open sequence gap before declaring loss
	// (TS-VID-043). Abandoning a gap by packet count instead makes loss
	// inside a keyframe unrecoverable.
	ReorderGapHold = 300 * time.Millisecond
)

// ControlKind is a UDP control message type — spec §4.1, Appendix A.1.
//
// The values are permanent (TS-EXT-003). A receiver must silently discard a
// datagram whose first byte is not one of them (TS-CTL-002).
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

// Caps is the capability bit field exchanged in the extended HELLO and
// HELLO_ACK — spec §5.1, Appendix A.3.
//
// A feature is in play on a link only if BOTH peers advertised it
// (TS-CAP-007); see Negotiate. Unknown bits must be ignored rather than
// rejected (TS-CAP-002), which is what lets a future revision add one.
type Caps uint8

// The assigned capability bits. Bits 6-7 are reserved and must be sent as
// zero (TS-CAP-001).
const (
	// CapNACK: the peer implements selective retransmission (spec §9.1).
	CapNACK Caps = 1 << 0
	// CapReceiverReport: the peer implements receiver reports and RTT pings
	// (spec §9.2).
	CapReceiverReport Caps = 1 << 1
	// CapFEC: the peer implements XOR parity (spec §9.3).
	CapFEC Caps = 1 << 2
	// CapRemoteControl is advertised by a SHARER only: this build and
	// platform can inject viewer input at all (TS-CAP-009). A viewer must not
	// offer Request Control without it (TS-CAP-008). It says nothing about
	// whether a live request will be granted — that is a runtime decision,
	// refused with controlRevoked.
	CapRemoteControl Caps = 1 << 3
	// CapAnnotations is advertised by a SHARER only: this sharer renders and
	// relays viewer annotations. A viewer must not accept annotation input
	// without it (TS-CAP-008), or it draws strokes that reach nobody.
	CapAnnotations Caps = 1 << 4
	// CapTenBit is advertised by a VIEWER only: this viewer can decode a
	// 10-bit bitstream (HEVC Main 10). A sharer encodes once for every
	// viewer, so it must not send 10-bit on a share where any admitted viewer
	// omitted this bit (TS-CAP-012) — including a legacy viewer whose
	// capability-less HELLO says nothing, which TS-CAP-006 requires be read
	// as no capabilities rather than as unknown.
	CapTenBit Caps = 1 << 5
)

// Has reports whether every bit in want is set.
func (c Caps) Has(want Caps) bool { return c&want == want }

// Negotiate returns the capabilities in play on a link: those both peers
// advertised (TS-CAP-007). Sending a NACK, receiver report or parity
// datagram on a link where the corresponding bit is missing from either
// side is a protocol violation, not a graceful degradation.
//
// The sharer-only bits (CapRemoteControl, CapAnnotations) travel one way, so
// a viewer reads them from the acknowledgement directly rather than through
// this function.
func Negotiate(local, remote Caps) Caps { return local & remote }

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

// String names the message, or its hex value when the byte is unassigned.
func (k ControlKind) String() string {
	if name, ok := controlNames[k]; ok {
		return name
	}
	return "control(" + hexByte(byte(k)) + ")"
}

func hexByte(b byte) string {
	const digits = "0123456789abcdef"
	return "0x" + string([]byte{digits[b>>4], digits[b&0x0F]})
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
func EncodeHello(caps Caps) []byte { return []byte{byte(Hello), byte(caps)} }

// DecodeHelloCaps reads the capability byte off a HELLO, returning 0 for the
// legacy one-byte form (TS-CAP-006) and for a datagram that is not a HELLO.
func DecodeHelloCaps(b []byte) Caps {
	if len(b) < 2 || b[0] != byte(Hello) {
		return 0
	}
	return Caps(b[1])
}

// EncodeHelloAck emits the plain five-byte acknowledgement when caps is nil,
// and the extended six-byte form otherwise. TS-CAP-004: the extended form is
// for viewers that advertised capabilities, and for nobody else.
func EncodeHelloAck(ssrc uint32, caps *Caps) []byte {
	out := make([]byte, 5, 6)
	out[0] = byte(HelloAck)
	binary.BigEndian.PutUint32(out[1:], ssrc)
	if caps != nil {
		out = append(out, byte(*caps))
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
func DecodeHelloAckTolerant(b []byte) (ssrc uint32, caps Caps, ok bool) {
	if len(b) < 5 || b[0] != byte(HelloAck) {
		return 0, 0, false
	}
	ssrc = binary.BigEndian.Uint32(b[1:5])
	if len(b) >= 6 {
		caps = Caps(b[5])
	}
	return ssrc, caps, true
}

// NACKEntry is one generic-NACK FCI entry: pid is the first missing sequence
// number, blp a bitmask of the 16 that follow it (spec §9.1).
type NACKEntry struct {
	PID uint16 `json:"pid"`
	BLP uint16 `json:"blp"`
}

// Missing expands the entry into the sequence numbers it names: the pid,
// followed by each of the 16 that follow it whose bit is set in the blp.
// Sequence arithmetic wraps at 2^16 (TS-GEN-003).
func (e NACKEntry) Missing() []uint16 {
	out := make([]uint16, 0, 17)
	out = append(out, e.PID)
	for i := 0; i < 16; i++ {
		if e.BLP&(1<<uint(i)) != 0 {
			out = append(out, e.PID+uint16(i)+1)
		}
	}
	return out
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
