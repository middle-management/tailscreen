package wire

import "encoding/binary"

// TCP message types — spec §10.1, Appendix A.2.
type MessageType byte

const (
	MsgAnnotation       MessageType = 0x03
	MsgRequestToShare   MessageType = 0x04
	MsgShareResponse    MessageType = 0x05
	MsgControlRequest   MessageType = 0x06
	MsgControlGranted   MessageType = 0x07
	MsgControlRevoked   MessageType = 0x08
	MsgInputEvent       MessageType = 0x09
	MsgControlReleased  MessageType = 0x0A
	MsgMetadataRequest  MessageType = 0x0B
	MsgMetadataResponse MessageType = 0x0C
)

const (
	FrameHeaderSize  = 5
	MaxPayloadLength = 1 << 20 // 1 MiB — TS-TCP-004
)

var knownMessageTypes = map[MessageType]bool{
	MsgAnnotation: true, MsgRequestToShare: true, MsgShareResponse: true,
	MsgControlRequest: true, MsgControlGranted: true, MsgControlRevoked: true,
	MsgInputEvent: true, MsgControlReleased: true, MsgMetadataRequest: true,
	MsgMetadataResponse: true,
}

// IsKnownMessageType reports whether a type byte is assigned. An unassigned
// one is skipped, not rejected (TS-TCP-003).
func IsKnownMessageType(t MessageType) bool { return knownMessageTypes[t] }

// EncodeFrame emits [type:1][length:4 BE][payload].
func EncodeFrame(t MessageType, payload []byte) []byte {
	out := make([]byte, 1, FrameHeaderSize+len(payload))
	out[0] = byte(t)
	out = binary.BigEndian.AppendUint32(out, uint32(len(payload)))
	return append(out, payload...)
}

// Frame is one recovered message: a known type byte and its raw payload.
// Decoding the payload is a separate layer (see payloads.go), so that a
// payload this implementation cannot decode does not disturb the framing.
type Frame struct {
	Type    MessageType
	Payload []byte
}

// FrameParser is the incremental parser. Feed it bytes as they arrive; it
// yields whole frames and tolerates a frame split across any number of TCP
// segments (TS-TCP-006) or several frames arriving together (TS-TCP-007).
//
// A frame declaring more than MaxPayloadLength poisons the parser
// permanently (TS-TCP-005): the stream cannot be resynchronised, because
// there is no way to know where the next frame starts, and the caller must
// close the connection. Rejection happens at header-parse time, before the
// payload is buffered (TS-TCP-004), so a bogus 4 GiB length cannot be used
// to grow memory.
type FrameParser struct {
	buf     []byte
	corrupt bool
}

// Corrupt reports whether the stream has been poisoned.
func (p *FrameParser) Corrupt() bool { return p.corrupt }

// Append feeds received bytes. A poisoned parser buffers nothing further.
func (p *FrameParser) Append(b []byte) {
	if p.corrupt {
		return
	}
	p.buf = append(p.buf, b...)
}

// Next returns the next complete frame with an assigned type, skipping frames
// whose type byte is unassigned. It returns ok=false when more bytes are
// needed or the stream is poisoned.
func (p *FrameParser) Next() (Frame, bool) {
	for {
		if p.corrupt || len(p.buf) < FrameHeaderSize {
			return Frame{}, false
		}
		t := MessageType(p.buf[0])
		length := int(binary.BigEndian.Uint32(p.buf[1:5]))
		if length > MaxPayloadLength {
			p.corrupt = true
			p.buf = nil
			return Frame{}, false
		}
		total := FrameHeaderSize + length
		if len(p.buf) < total {
			return Frame{}, false
		}
		payload := make([]byte, length)
		copy(payload, p.buf[FrameHeaderSize:total])
		p.buf = p.buf[total:]
		if !knownMessageTypes[t] {
			continue // TS-TCP-003
		}
		return Frame{Type: t, Payload: payload}, true
	}
}

// Drain returns every frame currently available.
func (p *FrameParser) Drain() []Frame {
	var out []Frame
	for {
		f, ok := p.Next()
		if !ok {
			return out
		}
		out = append(out, f)
	}
}
