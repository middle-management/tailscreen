package tailscreen

// RRAccounting is the pure receiver-report accounting behind the ~1 Hz
// reports (spec §9.2). It exists to make two numbers truthful:
//
//   - No baseline off-by-one: the packet that establishes the baseline is
//     both received AND expected, so N packets with no loss yield
//     expected == received == N. The baseline is held one before the first
//     extended sequence, in signed 64-bit space, so a first seq of 0 cannot
//     underflow.
//   - No duplicate inflation: arrivals are deduplicated against a sliding
//     bit-window over the extended sequence space, so only the FIRST arrival
//     of a seq counts. A served NACK retransmit IS the first arrival of its
//     seq and still counts as received — exactly RFC 3550's intent, and what
//     lets recovered loss read as recovered (TS-RRP-010).
//
// Not safe for concurrent use; the receive path is the only mutator.
type RRAccounting struct {
	// highestExt is the extended (wrap-monotone) sequence of the highest
	// packet received; -1 until the first packet establishes the baseline.
	highestExt int64
	// baselineExt makes expected = highestExt − baselineExt; it starts one
	// before the first packet and advances to highestExt on each MakeReport.
	baselineExt        int64
	receivedInInterval int
	seenBits           []uint64
}

// DedupeWindowBits is the sliding dedupe window in packets over the extended
// sequence space. Sized to cover the retransmit horizon comfortably: the
// sender's ring holds about a second of packets, so a served retransmit can
// legitimately land thousands of packets behind the highest at high bitrates.
// A window too small ignores those late fills and biases the loss fraction
// UP, triggering needless bitrate cuts.
const DedupeWindowBits = 4096

const rrWordCount = DedupeWindowBits / 64

// NewRRAccounting constructs empty accounting.
func NewRRAccounting() *RRAccounting {
	return &RRAccounting{
		highestExt:  -1,
		baselineExt: -1,
		seenBits:    make([]uint64, rrWordCount),
	}
}

// HasBaseline reports whether at least one packet has been observed.
func (r *RRAccounting) HasBaseline() bool { return r.highestExt >= 0 }

// ExtendSeq maps a 16-bit sequence number into the extended space, choosing
// the cycle that lands nearest near (wrap-aware). It may return a negative
// value for a straggler preceding the session start.
//
// Accepted limitation, matching the Swift implementation: a forward jump of
// more than 32768 packets is indistinguishable from a backward straggler in
// 16-bit space, so it extends backward and the arrival is ignored; the
// accounting self-heals on the next in-range packet.
func ExtendSeq(seq uint16, near int64) int64 {
	cycleBase := (near >> 16) << 16
	best := cycleBase + int64(seq)
	for _, alt := range [2]int64{best - 65536, best + 65536} {
		if absInt64(alt-near) < absInt64(best-near) {
			best = alt
		}
	}
	return best
}

func absInt64(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}

// Observe feeds one received video packet's sequence number.
func (r *RRAccounting) Observe(seq uint16) {
	if r.highestExt < 0 {
		// The first packet is both received and expected — the baseline sits
		// one before it so expected = highest − baseline counts it.
		r.highestExt = int64(seq)
		r.baselineExt = r.highestExt - 1
		r.receivedInInterval = 1
		r.setSeen(r.highestExt)
		return
	}
	ext := ExtendSeq(seq, r.highestExt)
	if ext > r.highestExt {
		// Clear the window slots the jump exposes, so stale bits from a lap
		// ago cannot alias as "already seen".
		r.clearSeenRange(r.highestExt+1, ext)
		r.highestExt = ext
	}
	// Only first arrivals inside the dedupe window count; stragglers older
	// than the window (or preceding the session) are ignored — their slot
	// now belongs to a newer seq.
	if ext < 0 || ext <= r.highestExt-DedupeWindowBits {
		return
	}
	if !r.isSeen(ext) {
		r.setSeen(ext)
		r.receivedInInterval++
	}
}

// MakeReport builds the values for one receiver report and resets the
// interval accounting. ok is false until the first packet arrives.
func (r *RRAccounting) MakeReport() (fracLostQ8 uint8, extHighestSeq uint32, ok bool) {
	if r.highestExt < 0 {
		return 0, 0, false
	}
	expected := int(r.highestExt - r.baselineExt)
	frac := 0
	if expected > 0 {
		lost := expected - r.receivedInInterval
		if lost < 0 {
			lost = 0
		}
		frac = lost * 256 / expected
		if frac > 255 {
			frac = 255
		}
	}
	// RFC 3550 form (cycles << 16 | highest): the low 32 bits of the
	// monotone extended counter.
	extForWire := uint32(r.highestExt)
	r.baselineExt = r.highestExt
	r.receivedInInterval = 0
	return uint8(frac), extForWire, true
}

func rrSlot(ext int64) (word int, mask uint64) {
	idx := int(ext % DedupeWindowBits)
	return idx / 64, 1 << uint(idx%64)
}

func (r *RRAccounting) isSeen(ext int64) bool {
	word, mask := rrSlot(ext)
	return r.seenBits[word]&mask != 0
}

func (r *RRAccounting) setSeen(ext int64) {
	word, mask := rrSlot(ext)
	r.seenBits[word] |= mask
}

func (r *RRAccounting) clearSeenRange(from, through int64) {
	if through < from {
		return
	}
	if through-from+1 >= DedupeWindowBits {
		for i := range r.seenBits {
			r.seenBits[i] = 0
		}
		return
	}
	ext := from
	if ext < 0 {
		ext = 0
	}
	for ; ext <= through; ext++ {
		word, mask := rrSlot(ext)
		r.seenBits[word] &^= mask
	}
}
