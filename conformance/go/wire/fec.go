package wire

import "encoding/binary"

// FEC parameters — spec §9.3, Appendix B.
const (
	FECMinGroupSize = 2
	FECMaxGroupSize = 16
	// The XORed per-packet prefix: [len:2][byte1][timestamp:4].
	FECPrefixBytes  = 7
	FECMinBodyBytes = FECPrefixBytes
	FECMaxBodyBytes = FECPrefixBytes + MaxRTPPayload
)

// EncodeFEC frames one parity datagram (spec §9.3).
func EncodeFEC(baseSeq uint16, count int, body []byte) []byte {
	out := make([]byte, 1, 4+len(body))
	out[0] = byte(FEC)
	out = binary.BigEndian.AppendUint16(out, baseSeq)
	out = append(out, byte(count))
	return append(out, body...)
}

// DecodeFEC parses a parity datagram. This is untrusted input, so every field
// is bounds-checked: a body too short to describe any packet, a body larger
// than any legitimate parity, or a group size outside 2…16 is rejected rather
// than fed to the solver (TS-FEC-001, TS-FEC-002, TS-FEC-003).
func DecodeFEC(b []byte) (baseSeq uint16, count int, body []byte, ok bool) {
	if len(b) < 4+FECMinBodyBytes || b[0] != byte(FEC) {
		return 0, 0, nil, false
	}
	if len(b) > 4+FECMaxBodyBytes {
		return 0, 0, nil, false
	}
	count = int(b[3])
	if count < FECMinGroupSize || count > FECMaxGroupSize {
		return 0, 0, nil, false
	}
	return binary.BigEndian.Uint16(b[1:3]), count, b[4:], true
}

// xorInto folds one packet's covered fields — [len:2][byte1][timestamp:4]
// and the payload — into body. It is the same operation on both sides: the
// sender XORs every member to build the parity, the receiver XORs the
// survivors back out to solve for the missing one.
func xorInto(body []byte, packet []byte) {
	body[0] ^= byte(len(packet) >> 8)
	body[1] ^= byte(len(packet))
	body[2] ^= packet[1]
	for i := 0; i < 4; i++ {
		body[3+i] ^= packet[4+i]
	}
	n := len(packet) - RTPHeaderSize
	if room := len(body) - FECPrefixBytes; n > room {
		n = room
	}
	for i := 0; i < n; i++ {
		body[FECPrefixBytes+i] ^= packet[RTPHeaderSize+i]
	}
}

// ParityBody computes the XOR parity over one group, zero-padded to the
// longest member. It returns nil for a degenerate group — fewer than two
// members (TS-FEC-006), or a member too short to be an RTP packet.
func ParityBody(packets [][]byte) []byte {
	if len(packets) < FECMinGroupSize {
		return nil
	}
	maxLen := 0
	for _, p := range packets {
		if len(p) < RTPHeaderSize {
			return nil
		}
		if len(p) > maxLen {
			maxLen = len(p)
		}
	}
	body := make([]byte, FECPrefixBytes+(maxLen-RTPHeaderSize))
	for _, p := range packets {
		xorInto(body, p)
	}
	return body
}

// Recover reconstructs the single missing packet of a group from the
// surviving members and the parity body (TS-FEC-009). missingSeq comes from
// the receiver's own gap tracking and ssrc from any member's header — neither
// is carried in the parity.
//
// It returns nil on any inconsistency: a member too short to be RTP, a member
// whose payload exceeds the parity's padded region (so this parity cannot have
// covered it), or a solved length that is impossible (TS-FEC-010). A malformed
// parity must never emit a torn packet into the depacketizer.
func Recover(missingSeq uint16, ssrc uint32, members [][]byte, body []byte) []byte {
	if len(body) < FECMinBodyBytes {
		return nil
	}
	for _, m := range members {
		if len(m) < RTPHeaderSize {
			return nil
		}
		if len(m)-RTPHeaderSize > len(body)-FECPrefixBytes {
			return nil
		}
	}
	solved := make([]byte, len(body))
	copy(solved, body)
	for _, m := range members {
		xorInto(solved, m)
	}

	recoveredLen := int(binary.BigEndian.Uint16(solved[0:2]))
	if recoveredLen < RTPHeaderSize {
		return nil
	}
	if recoveredLen-RTPHeaderSize > len(solved)-FECPrefixBytes {
		return nil
	}

	out := make([]byte, 0, recoveredLen)
	out = append(out, 0x80) // TS-VID-001: constant across our packetizers
	out = append(out, solved[2])
	out = binary.BigEndian.AppendUint16(out, missingSeq)
	out = append(out, solved[3:7]...)
	out = binary.BigEndian.AppendUint32(out, ssrc)
	out = append(out, solved[FECPrefixBytes:FECPrefixBytes+(recoveredLen-RTPHeaderSize)]...)
	return out
}
