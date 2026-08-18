package tailscreen

// ReorderRelease is one packet released to the assembler, in ascending
// sequence order. LostBefore is true when a gap was abandoned immediately
// before this packet — the assembler latches it onto the access unit so the
// viewer still requests a keyframe for genuine loss (TS-VID-044).
type ReorderRelease struct {
	Packet     []byte
	LostBefore bool
}

// ReorderBuffer absorbs the reordering and duplication a real WAN path
// produces, so that a single out-of-order arrival is not mistaken for loss
// (TS-VID-040, TS-VID-041).
//
// It has two modes, and the difference between them is the whole reason this
// type is subtle:
//
//   - GapHoldNs == 0: gaps are abandoned by COUNT, once more than MaxDepth
//     packets are held. Right for a path that only reorders.
//   - GapHoldNs > 0: gaps are abandoned by TIME (TS-VID-043), with MaxDepth
//     left as a memory bound. This is what selective retransmission needs — a
//     count-based window overflows in tens of milliseconds at video bitrate,
//     long before a retransmit can arrive one round trip later, so a keyframe
//     that lost a packet would be torn and never reassembled.
//
// All sequence arithmetic wraps at 2^16 (TS-GEN-003). The zero value is not
// usable; construct with NewReorderBuffer.
type ReorderBuffer struct {
	maxDepth  int
	gapHoldNs uint64

	// nextSeq is the sequence number we want to release next; valid only once
	// hasNext is set, which distinguishes "waiting for seq 0" from "no packet
	// has ever arrived".
	nextSeq uint16
	hasNext bool

	buffered map[uint16][]byte

	// oldestGapNs is when the current front-gap hold began, and holds only
	// while something is buffered.
	oldestGapNs uint64
	hasGapClock bool

	skippedGapCount int
}

// NewReorderBuffer constructs a buffer. maxDepth is the hard cap on held
// packets; gapHoldNs of 0 selects count-based abandonment. maxDepth is taken
// literally — 0 abandons a gap the moment anything would be held, exactly as
// the Swift implementation does; clamping it here would be a one-sided
// divergence in a differentially-pinned pair.
func NewReorderBuffer(maxDepth int, gapHoldNs uint64) *ReorderBuffer {
	return &ReorderBuffer{
		maxDepth:  maxDepth,
		gapHoldNs: gapHoldNs,
		buffered:  make(map[uint16][]byte),
	}
}

// SkippedGapCount is the number of gaps abandoned since construction. It
// survives Reset on purpose: it is a session tally for diagnostics, not
// state.
func (b *ReorderBuffer) SkippedGapCount() int { return b.skippedGapCount }

// Reset forgets the sequence position and drops anything held, for a stream
// that has resynchronised.
func (b *ReorderBuffer) Reset() {
	b.hasNext = false
	b.nextSeq = 0
	for k := range b.buffered {
		delete(b.buffered, k)
	}
	b.hasGapClock = false
	b.oldestGapNs = 0
}

// Push inserts one received packet at time nowNs and returns whatever is now
// releasable, in order. Pass nowNs of 0 in count-based mode, where no clock
// is consulted.
//
// The packet bytes are copied on entry: the caller's slice is never retained
// or aliased, so a receive loop can reuse one read buffer across calls and
// hold released packets indefinitely — the same contract Swift's Data value
// semantics give the original implementation.
func (b *ReorderBuffer) Push(seq uint16, packet []byte, nowNs uint64) []ReorderRelease {
	packet = append([]byte(nil), packet...)
	if !b.hasNext {
		// First packet of a (re)synced stream: release it and take its
		// sequence as the origin.
		b.hasNext = true
		b.nextSeq = seq + 1
		return []ReorderRelease{{Packet: packet}}
	}

	ahead := seq - b.nextSeq // wraps, so this is the forward distance mod 2^16
	switch {
	case ahead == 0:
		// Exactly what we were waiting for: release it, then everything held
		// contiguously behind it.
		b.nextSeq = seq + 1
		out := []ReorderRelease{{Packet: packet}}
		out = b.drainContiguous(out)
		b.refreshGapClock(nowNs)
		return out

	case ahead > 1<<15:
		// Behind us: the distance wrapped past the halfway point, so this is a
		// duplicate or a straggler we already moved past. Drop it — never
		// treat it as corruption (TS-VID-041).
		return nil
	}

	// A future packet. Hold it until the gap in front of it fills.
	b.buffered[seq] = packet
	if !b.hasGapClock {
		b.oldestGapNs = nowNs
		b.hasGapClock = true
	}

	// The memory cap always wins: a loss storm must never grow unbounded.
	if len(b.buffered) > b.maxDepth {
		out := b.skipGap()
		b.refreshGapClock(nowNs)
		return out
	}

	// The time bound. Give a retransmit its round trip, then give up, so that
	// genuine loss cannot wedge the stream forever.
	if b.gapHoldNs > 0 && b.hasGapClock && nowNs-b.oldestGapNs >= b.gapHoldNs {
		out := b.skipGap()
		b.refreshGapClock(nowNs)
		return out
	}
	return nil
}

// refreshGapClock restarts the hold for whatever gap now sits at the front —
// a different missing sequence from the one just resolved — or clears it when
// nothing is held.
func (b *ReorderBuffer) refreshGapClock(nowNs uint64) {
	if len(b.buffered) == 0 {
		b.hasGapClock = false
		b.oldestGapNs = 0
		return
	}
	b.oldestGapNs = nowNs
	b.hasGapClock = true
}

func (b *ReorderBuffer) drainContiguous(out []ReorderRelease) []ReorderRelease {
	for {
		packet, ok := b.buffered[b.nextSeq]
		if !ok {
			return out
		}
		delete(b.buffered, b.nextSeq)
		out = append(out, ReorderRelease{Packet: packet})
		b.nextSeq++
	}
}

// skipGap declares the missing packet lost and resumes from the lowest held
// sequence, marking it so the caller knows loss preceded it.
func (b *ReorderBuffer) skipGap() []ReorderRelease {
	b.skippedGapCount++
	if len(b.buffered) == 0 {
		return nil
	}

	// "Lowest" is by distance from what we want, not by numeric value, so the
	// choice stays right across a sequence wrap.
	var lowest uint16
	first := true
	for seq := range b.buffered {
		if first || seq-b.nextSeq < lowest-b.nextSeq {
			lowest = seq
			first = false
		}
	}

	packet := b.buffered[lowest]
	delete(b.buffered, lowest)
	b.nextSeq = lowest + 1
	out := []ReorderRelease{{Packet: packet, LostBefore: true}}
	return b.drainContiguous(out)
}
