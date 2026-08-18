package tailscreen

import "encoding/binary"

// VideoAccessUnit is one reassembled frame, in AVCC form: each NAL unit
// prefixed with its 4-byte big-endian length, which is what a decoder is
// handed.
type VideoAccessUnit struct {
	AVCC        []byte
	ContainsIDR bool
	Timestamp   uint32
	// LostBeforeThisAU is latched from an abandoned gap and survives the
	// access units discarded in between, so the caller still knows to ask for
	// a keyframe (TS-VID-044).
	LostBeforeThisAU bool
	Codec            string // "h264" or "hevc"
}

// Depacketizer reassembles RTP packets into access units (TS-VID-035). A
// ReorderBuffer sits in front of it absorbing reordering and duplication;
// genuine loss still discards the partial access unit, so a decoder never
// sees a torn frame.
//
// One type serves both codecs because they differ in only five places — the
// payload type accepted, the minimum payload length, the payload header
// layout, which NAL types mean "decodable from scratch", and the codec tag —
// and writing it twice would be two chances to fix a bug once.
type Depacketizer struct {
	hevc bool

	ssrc    uint32
	hasSSRC bool

	currentTimestamp    uint32
	hasCurrentTimestamp bool
	currentAU           []byte
	currentHasIDR       bool
	currentAUCorrupted  bool

	fuBuffer []byte
	inFU     bool

	// pendingLossSignal stays latched across discarded access units, so the
	// next clean one carries the loss flag.
	pendingLossSignal bool

	reorder    *ReorderBuffer
	readyQueue []VideoAccessUnit

	tornAUCount int
}

// NewH264Depacketizer builds a depacketizer for RFC 6184 payloads.
func NewH264Depacketizer(reorderDepth int, gapHoldNs uint64) *Depacketizer {
	return &Depacketizer{reorder: NewReorderBuffer(reorderDepth, gapHoldNs)}
}

// NewH265Depacketizer builds a depacketizer for RFC 7798 payloads.
func NewH265Depacketizer(reorderDepth int, gapHoldNs uint64) *Depacketizer {
	return &Depacketizer{hevc: true, reorder: NewReorderBuffer(reorderDepth, gapHoldNs)}
}

// TornAUCount is the number of access units that completed and were then
// discarded as torn.
//
// It is counted rather than silent because the drop is otherwise invisible:
// the caller sees Ingest return nil, which is also what an ordinary mid-frame
// packet returns. A blank viewer whose access-unit count sits still cannot
// otherwise be told from one where every frame arrives and is discarded here,
// and those two want opposite fixes.
func (d *Depacketizer) TornAUCount() int { return d.tornAUCount }

// SkippedGapCount is the number of gaps the reorder buffer gave up on.
func (d *Depacketizer) SkippedGapCount() int { return d.reorder.SkippedGapCount() }

func (d *Depacketizer) payloadType() uint8 {
	if d.hevc {
		return PTHEVC
	}
	return PTH264
}

func (d *Depacketizer) codecName() string {
	if d.hevc {
		return "hevc"
	}
	return "h264"
}

// minPayload is the shortest payload that could carry a NAL header: one byte
// for H.264, two for HEVC.
func (d *Depacketizer) minPayload() int {
	if d.hevc {
		return 2
	}
	return 1
}

// Ingest feeds one received packet at time nowNs and returns a completed
// access unit if the marker bit finished one. nowNs drives the reorder
// buffer's time-based hold; pass 0 in count-based mode.
//
// The packet bytes are never retained past the call (the embedded reorder
// buffer copies on entry), so a receive loop can reuse one read buffer.
//
// At most one access unit comes back per call even when a late packet
// completes several — the rest queue up and arrive one per subsequent call,
// or all at once from DrainReady.
func (d *Depacketizer) Ingest(packet []byte, nowNs uint64) *VideoAccessUnit {
	header, _, ok := DecodeRTPHeader(packet)
	if !ok || header.PayloadType != d.payloadType() {
		return nil
	}

	// Lock onto the first SSRC seen and discard state if it changes, which
	// happens when the sender restarts.
	if d.hasSSRC && d.ssrc != header.SSRC {
		d.reset()
		d.ssrc = header.SSRC
	} else if !d.hasSSRC {
		d.ssrc = header.SSRC
		d.hasSSRC = true
	}

	for _, release := range d.reorder.Push(header.Sequence, packet, nowNs) {
		d.assemble(release.Packet, release.LostBefore)
	}
	if len(d.readyQueue) == 0 {
		return nil
	}
	au := d.readyQueue[0]
	d.readyQueue = d.readyQueue[1:]
	return &au
}

// DrainReady returns every access unit completed but not yet handed back.
func (d *Depacketizer) DrainReady() []VideoAccessUnit {
	out := d.readyQueue
	d.readyQueue = nil
	return out
}

func (d *Depacketizer) assemble(packet []byte, lostBefore bool) {
	header, payloadOffset, ok := DecodeRTPHeader(packet)
	if !ok {
		return
	}

	if lostBefore {
		d.currentAUCorrupted = true
		d.pendingLossSignal = true
		d.inFU = false
		d.fuBuffer = d.fuBuffer[:0]
	}

	// A timestamp change with no marker means the previous frame's marker
	// packet was lost. Throw away what accumulated and start fresh.
	if d.hasCurrentTimestamp && d.currentTimestamp != header.Timestamp {
		d.currentAUCorrupted = true
		d.currentAU = d.currentAU[:0]
		d.currentHasIDR = false
		d.inFU = false
		d.fuBuffer = d.fuBuffer[:0]
		d.pendingLossSignal = true
	}
	d.currentTimestamp = header.Timestamp
	d.hasCurrentTimestamp = true

	payload := packet[payloadOffset:]
	if len(payload) < d.minPayload() {
		d.currentAUCorrupted = true
	} else {
		d.handlePayload(payload)
	}

	if header.Marker {
		if au := d.flushAU(header.Timestamp); au != nil {
			d.readyQueue = append(d.readyQueue, *au)
		}
	}
}

func (d *Depacketizer) handlePayload(payload []byte) {
	if d.hevc {
		d.handleHEVCPayload(payload)
		return
	}
	d.handleH264Payload(payload)
}

func (d *Depacketizer) handleH264Payload(payload []byte) {
	nalHeader := payload[0]
	switch nalType := nalHeader & 0x1F; {
	case nalType >= 1 && nalType <= 23:
		// A single-NAL packet: the payload is the whole NAL.
		d.appendNAL(payload)

	case nalType == 28:
		// FU-A: [FU indicator][FU header][fragment…].
		if len(payload) < 2 {
			d.currentAUCorrupted = true
			return
		}
		fuIndicator, fuHeader := payload[0], payload[1]
		isStart := fuHeader&0x80 != 0
		isEnd := fuHeader&0x40 != 0
		originalType := fuHeader & 0x1F
		fragment := payload[2:]

		if isStart {
			// Rebuild the original NAL header: F and NRI from the indicator,
			// type from the FU header.
			d.fuBuffer = append(d.fuBuffer[:0], (fuIndicator&0xE0)|originalType)
			d.fuBuffer = append(d.fuBuffer, fragment...)
			d.inFU = true
		} else if d.inFU {
			d.fuBuffer = append(d.fuBuffer, fragment...)
		} else {
			// A middle or end fragment with no start: packets were missed.
			d.currentAUCorrupted = true
			return
		}

		if isEnd && d.inFU {
			d.appendNAL(d.fuBuffer)
			d.fuBuffer = d.fuBuffer[:0]
			d.inFU = false
		}

	default:
		// STAP-A (24), MTAP (26–27), FU-B (29) and the reserved types are
		// never emitted by this protocol (TS-VID-034), so mark the access
		// unit corrupt rather than guess at them.
		d.currentAUCorrupted = true
	}
}

func (d *Depacketizer) handleHEVCPayload(payload []byte) {
	switch nalType := (payload[0] >> 1) & 0x3F; {
	case nalType <= 47:
		d.appendNAL(payload)

	case nalType == 49:
		// FU: [PayloadHdr:2][FU header:1][fragment…].
		if len(payload) < 3 {
			d.currentAUCorrupted = true
			return
		}
		payloadHdr0, payloadHdr1, fuHeader := payload[0], payload[1], payload[2]
		isStart := fuHeader&0x80 != 0
		isEnd := fuHeader&0x40 != 0
		originalType := fuHeader & 0x3F
		fragment := payload[3:]

		if isStart {
			// Rebuild the original NAL header: F and the top LayerId bit come
			// from PayloadHdr byte 0, the original type goes back into bits
			// 1–6 of it, and byte 1 passes through untouched.
			originalH0 := (payloadHdr0 & 0x80) | ((originalType & 0x3F) << 1) | (payloadHdr0 & 0x01)
			d.fuBuffer = append(d.fuBuffer[:0], originalH0, payloadHdr1)
			d.fuBuffer = append(d.fuBuffer, fragment...)
			d.inFU = true
		} else if d.inFU {
			d.fuBuffer = append(d.fuBuffer, fragment...)
		} else {
			d.currentAUCorrupted = true
			return
		}

		if isEnd && d.inFU {
			d.appendNAL(d.fuBuffer)
			d.fuBuffer = d.fuBuffer[:0]
			d.inFU = false
		}

	default:
		// 48 is AP, 50 is PACI, 51–63 are reserved. None are emitted here.
		d.currentAUCorrupted = true
	}
}

func (d *Depacketizer) appendNAL(nal []byte) {
	if len(nal) == 0 {
		return
	}
	if d.hevc {
		// 16–21 are the IRAP types (BLA/IDR/CRA): the access unit is
		// decodable from scratch.
		if nalType := (nal[0] >> 1) & 0x3F; nalType >= 16 && nalType <= 21 {
			d.currentHasIDR = true
		}
	} else if nal[0]&0x1F == 5 {
		d.currentHasIDR = true
	}

	d.currentAU = binary.BigEndian.AppendUint32(d.currentAU, uint32(len(nal)))
	d.currentAU = append(d.currentAU, nal...)
}

func (d *Depacketizer) flushAU(timestamp uint32) *VideoAccessUnit {
	// Every field is captured before the reset below clears it.
	corrupted := d.currentAUCorrupted || len(d.currentAU) == 0
	lostBefore := d.pendingLossSignal
	avcc := d.currentAU
	hasIDR := d.currentHasIDR

	// A fresh slice rather than a truncation: the access unit just captured
	// aliases this backing array, and reusing it would overwrite bytes the
	// caller is about to read.
	d.currentAU = nil
	d.currentHasIDR = false
	d.currentAUCorrupted = false
	d.inFU = false
	d.fuBuffer = d.fuBuffer[:0]
	d.hasCurrentTimestamp = false

	if corrupted {
		// Drop the access unit but keep the loss flag latched, so the next
		// clean one still carries it.
		d.tornAUCount++
		return nil
	}

	d.pendingLossSignal = false
	return &VideoAccessUnit{
		AVCC:             avcc,
		ContainsIDR:      hasIDR,
		Timestamp:        timestamp,
		LostBeforeThisAU: lostBefore,
		Codec:            d.codecName(),
	}
}

func (d *Depacketizer) reset() {
	d.reorder.Reset()
	d.readyQueue = nil
	d.hasCurrentTimestamp = false
	d.currentAU = nil
	d.currentHasIDR = false
	d.currentAUCorrupted = false
	d.fuBuffer = d.fuBuffer[:0]
	d.inFU = false
	d.pendingLossSignal = false
}
