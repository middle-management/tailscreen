package wire

import "encoding/binary"

// RTP constants — spec §7, Appendix A.4/A.5.
const (
	RTPHeaderSize = 12
	MaxRTPPayload = 1100 // TS-VID-030

	PTH264        = 96
	PTHEVC        = 97
	PTVoice       = 98
	PTSystemAudio = 99

	SSRCSharerVoice = 0
	SSRCSystemAudio = 1
	SSRCFirstViewer = 2

	VideoClockHz     = 90000
	AudioClockHz     = 48000
	OpusFrameSamples = 960
)

// RTPHeader is the fixed 12-byte header. Tailscreen emits no CSRCs and no
// extension (TS-VID-001), but a receiver must tolerate both (TS-VID-003).
type RTPHeader struct {
	Marker      bool
	PayloadType uint8
	Sequence    uint16
	Timestamp   uint32
	SSRC        uint32
}

// EncodeRTPHeader writes V=2, P=0, X=0, CC=0 and the five carried fields.
func EncodeRTPHeader(h RTPHeader) []byte {
	out := make([]byte, 0, RTPHeaderSize)
	out = append(out, 0x80)
	b1 := h.PayloadType & 0x7F
	if h.Marker {
		b1 |= 0x80
	}
	out = append(out, b1)
	out = binary.BigEndian.AppendUint16(out, h.Sequence)
	out = binary.BigEndian.AppendUint32(out, h.Timestamp)
	out = binary.BigEndian.AppendUint32(out, h.SSRC)
	return out
}

// DecodeRTPHeader parses the fixed header and returns the offset at which the
// payload begins, having skipped any CSRC list and header extension. It
// rejects a packet that is too short for the offset it computes, and one
// whose version is not 2 (TS-VID-002, TS-VID-003).
func DecodeRTPHeader(b []byte) (RTPHeader, int, bool) {
	if len(b) < RTPHeaderSize {
		return RTPHeader{}, 0, false
	}
	if b[0]&0xC0 != 0x80 {
		return RTPHeader{}, 0, false
	}
	csrcCount := int(b[0] & 0x0F)
	hasExt := b[0]&0x10 != 0

	h := RTPHeader{
		Marker:      b[1]&0x80 != 0,
		PayloadType: b[1] & 0x7F,
		Sequence:    binary.BigEndian.Uint16(b[2:4]),
		Timestamp:   binary.BigEndian.Uint32(b[4:8]),
		SSRC:        binary.BigEndian.Uint32(b[8:12]),
	}

	offset := RTPHeaderSize + csrcCount*4
	if hasExt {
		if len(b) < offset+4 {
			return RTPHeader{}, 0, false
		}
		extWords := int(binary.BigEndian.Uint16(b[offset+2 : offset+4]))
		offset += 4 + extWords*4
	}
	if len(b) < offset {
		return RTPHeader{}, 0, false
	}
	return h, offset, true
}

// PacketizeH264 turns one access unit's NAL units into RTP packets
// (TS-VID-031, TS-VID-032). The marker bit lands on the last packet of the
// access unit and nowhere else (TS-VID-006).
func PacketizeH264(nals [][]byte, timestamp uint32, ssrc uint32, startSeq uint16) [][]byte {
	var packets [][]byte
	seq := startSeq
	for _, nal := range nals {
		if len(nal) == 0 {
			continue
		}
		if len(nal) <= MaxRTPPayload {
			p := EncodeRTPHeader(RTPHeader{PayloadType: PTH264, Sequence: seq, Timestamp: timestamp, SSRC: ssrc})
			packets = append(packets, append(p, nal...))
			seq++
			continue
		}
		nalHeader := nal[0]
		fuIndicator := (nalHeader & 0x60) | 28
		nalType := nalHeader & 0x1F
		body := nal[1:]
		const fragSize = MaxRTPPayload - 2
		for off, first := 0, true; off < len(body); first = false {
			take := fragSize
			if rem := len(body) - off; rem < take {
				take = rem
			}
			last := off+take == len(body)
			fuHeader := nalType
			if first {
				fuHeader |= 0x80
			}
			if last {
				fuHeader |= 0x40
			}
			p := EncodeRTPHeader(RTPHeader{PayloadType: PTH264, Sequence: seq, Timestamp: timestamp, SSRC: ssrc})
			p = append(p, fuIndicator, fuHeader)
			p = append(p, body[off:off+take]...)
			packets = append(packets, p)
			seq++
			off += take
		}
	}
	return markLast(packets)
}

// PacketizeHEVC is the RFC 7798 counterpart (TS-VID-033). A NAL shorter than
// its own two-byte header is dropped (TS-VID-036).
func PacketizeHEVC(nals [][]byte, timestamp uint32, ssrc uint32, startSeq uint16) [][]byte {
	var packets [][]byte
	seq := startSeq
	for _, nal := range nals {
		if len(nal) < 2 {
			continue
		}
		if len(nal) <= MaxRTPPayload {
			p := EncodeRTPHeader(RTPHeader{PayloadType: PTHEVC, Sequence: seq, Timestamp: timestamp, SSRC: ssrc})
			packets = append(packets, append(p, nal...))
			seq++
			continue
		}
		nh0, nh1 := nal[0], nal[1]
		originalType := (nh0 >> 1) & 0x3F
		payloadHdr0 := (nh0 & 0x80) | (49 << 1) | (nh0 & 0x01)
		payloadHdr1 := nh1
		body := nal[2:]
		const fragSize = MaxRTPPayload - 3
		for off, first := 0, true; off < len(body); first = false {
			take := fragSize
			if rem := len(body) - off; rem < take {
				take = rem
			}
			last := off+take == len(body)
			fuHeader := originalType & 0x3F
			if first {
				fuHeader |= 0x80
			}
			if last {
				fuHeader |= 0x40
			}
			p := EncodeRTPHeader(RTPHeader{PayloadType: PTHEVC, Sequence: seq, Timestamp: timestamp, SSRC: ssrc})
			p = append(p, payloadHdr0, payloadHdr1, fuHeader)
			p = append(p, body[off:off+take]...)
			packets = append(packets, p)
			seq++
			off += take
		}
	}
	return markLast(packets)
}

func markLast(packets [][]byte) [][]byte {
	if len(packets) > 0 {
		packets[len(packets)-1][1] |= 0x80
	}
	return packets
}
