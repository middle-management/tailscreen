package tailscreen

import "sort"

// NACKAction is one decision the scheduler hands back: either a batch of
// sequence numbers to request in a single NACK datagram, or a fallback to a
// keyframe request. Exactly one of the fields is set.
type NACKAction struct {
	// Seqs, when non-empty, is the set of missing sequence numbers to pack
	// into one NACK datagram (PackFCI turns them into (pid, blp) entries).
	Seqs []uint16
	// PLI, when true, abandons selective retransmission for a keyframe
	// request — recovery is then never worse than the plain PLI path
	// (TS-REC-001).
	PLI bool
}

// NACKSchedulerConfig carries the scheduler's tunables. The zero value of any
// field selects the default — which means an explicit zero is NOT
// representable at construction, unlike the Swift initializer, where 0 is
// taken literally. For the two fields where zero is genuinely meaningful —
// ReorderToleranceNs and ReorderPacketTolerance, whose zeros mean "every gap
// is instantly NACK-eligible" — call SetReorderTolerances(0, 0) after
// construction; it takes its arguments literally. The remaining fields have
// no useful zero (a scheduler with MaxAttempts 0 or MaxGaps 0 is the plain
// PLI path wearing a costume), so 0-means-default costs nothing there.
type NACKSchedulerConfig struct {
	// ReorderToleranceNs is how old a gap must be before it is NACK-eligible;
	// below it a reordered packet still fills the gap with no NACK
	// (TS-NCK-007).
	ReorderToleranceNs uint64
	// ReorderPacketTolerance makes a gap eligible early once this many newer
	// packets have piled up behind it — a run of newer packets means the
	// missing one is not merely reordered.
	ReorderPacketTolerance int
	// MaxAttempts is the NACK attempts per gap before abandoning it to a PLI.
	MaxAttempts int
	// ReNackFloorNs floors the re-NACK interval; the effective interval is
	// max(1.5 × RTT, floor).
	ReNackFloorNs uint64
	// RingWindowNs abandons a gap older than this regardless of attempts —
	// it has aged past the sender's retransmit ring (TS-NCK-005) and a NACK
	// cannot be served.
	RingWindowNs uint64
	// MaxNacksPerSecond caps NACK datagrams per second.
	MaxNacksPerSecond int
	// MaxGaps bounds the tracked-gap set; a wider jump is a stream
	// discontinuity answered with a PLI, and overflow beyond it is abandoned
	// rather than grown (TS-SEC-003).
	MaxGaps int
	// InitialRTTNs seeds the RTT estimate before any NACK→retransmit round
	// trip has been measured.
	InitialRTTNs uint64
}

// Default scheduler tunables, mirroring the Swift implementation's.
const (
	DefaultReorderToleranceNs     = 15_000_000
	DefaultReorderPacketTolerance = 3
)

func (c NACKSchedulerConfig) withDefaults() NACKSchedulerConfig {
	if c.ReorderToleranceNs == 0 {
		c.ReorderToleranceNs = DefaultReorderToleranceNs
	}
	if c.ReorderPacketTolerance == 0 {
		c.ReorderPacketTolerance = DefaultReorderPacketTolerance
	}
	if c.MaxAttempts == 0 {
		c.MaxAttempts = 3
	}
	if c.ReNackFloorNs == 0 {
		c.ReNackFloorNs = 40_000_000
	}
	if c.RingWindowNs == 0 {
		c.RingWindowNs = 1_000_000_000
	}
	if c.MaxNacksPerSecond == 0 {
		c.MaxNacksPerSecond = 50
	}
	if c.MaxGaps == 0 {
		c.MaxGaps = 256
	}
	if c.InitialRTTNs == 0 {
		c.InitialRTTNs = 60_000_000
	}
	return c
}

type nackGap struct {
	firstSeenNs uint64
	attempts    int
	lastNackNs  uint64
	// newerSeen counts newer packets arrived since the gap opened; reaching
	// ReorderPacketTolerance makes the gap eligible before the time
	// tolerance elapses.
	newerSeen int
}

// NACKScheduler is the pure, deterministic sequence-gap tracker driving
// selective retransmission on the receiver. Fed one (seq, nowNs) per received
// video packet, it detects gaps, waits out a reorder tolerance so pure
// reordering produces zero NACKs (TS-NCK-007), then emits NACKs on an
// RTT-derived cadence up to an attempt cap, and finally converts an
// unrecoverable gap to a PLI.
//
// No I/O and no wall clock: the caller injects nowNs, so every decision is
// reproducible. Not safe for concurrent use; the caller owns serialization.
type NACKScheduler struct {
	cfg NACKSchedulerConfig

	highestSeq uint16
	hasHighest bool
	gaps       map[uint16]*nackGap
	rttNs      uint64
	// nackStampsNs holds recent NACK send times for the per-second cap.
	nackStampsNs []uint64
	// nackRecoveredCount counts gaps that were NACKed and later filled — link
	// losses a retransmit repaired, shipped in the extended receiver report
	// so the sender's FEC arm can reconstruct raw link loss (TS-RRP-010).
	nackRecoveredCount int
}

// NewNACKScheduler constructs a scheduler; zero-value config fields select
// the defaults.
func NewNACKScheduler(cfg NACKSchedulerConfig) *NACKScheduler {
	c := cfg.withDefaults()
	return &NACKScheduler{
		cfg:   c,
		gaps:  make(map[uint16]*nackGap),
		rttNs: c.InitialRTTNs,
	}
}

// RTTEstimateNs is the current RTT estimate, seeded from the config and
// adapted by each NACK→retransmit round trip.
func (s *NACKScheduler) RTTEstimateNs() uint64 { return s.rttNs }

// HasOpenGaps reports whether any gap is being tracked.
func (s *NACKScheduler) HasOpenGaps() bool { return len(s.gaps) > 0 }

// DrainNackRecovered reads and resets the count of packets recovered by a
// served retransmit since the last call — one drain per receiver report.
func (s *NACKScheduler) DrainNackRecovered() int {
	n := s.nackRecoveredCount
	s.nackRecoveredCount = 0
	return n
}

// SetReorderTolerances switches the eligibility tolerances in place — FEC
// arming relaxes them so parity gets first shot at every gap, disarming
// restores the defaults — WITHOUT dropping tracked gaps or the adapted RTT
// estimate, which rebuilding the scheduler would.
func (s *NACKScheduler) SetReorderTolerances(toleranceNs uint64, packetTolerance int) {
	s.cfg.ReorderToleranceNs = toleranceNs
	s.cfg.ReorderPacketTolerance = packetTolerance
}

// Observe feeds one received video packet's sequence number, updating gap
// tracking and returning any actions now due.
func (s *NACKScheduler) Observe(seq uint16, nowNs uint64) []NACKAction {
	if !s.hasHighest {
		s.hasHighest = true
		s.highestSeq = seq
		return s.evaluate(nowNs)
	}

	forward := seq - s.highestSeq // wrap-safe forward distance mod 2^16
	if forward == 0 || forward > 1<<15 {
		// A duplicate or an old straggler — possibly a served retransmit. If
		// it fills a tracked gap that was actually NACKed, the fill is a
		// genuine recovery: it gives an RTT sample (the NACK→retransmit round
		// trip) and counts toward the raw-loss signal. A gap that fills
		// before any NACK fired was pure reordering and counts as neither.
		if filled, ok := s.gaps[seq]; ok {
			delete(s.gaps, seq)
			if filled.attempts > 0 && filled.lastNackNs != 0 {
				s.updateRTTSample(nowNs - filled.lastNackNs)
				s.nackRecoveredCount++
			}
		}
		return s.evaluate(nowNs)
	}

	// A jump wider than MaxGaps is a stream discontinuity (long stall, burst
	// loss, resync) — not selectively repairable. The depacketizer's own
	// loss-PLI is suppressed in NACK mode, so the PLI must come from here or
	// a wide gap yields neither NACK nor keyframe and the stream freezes.
	if int(forward) > s.cfg.MaxGaps {
		s.gaps = make(map[uint16]*nackGap)
		s.highestSeq = seq
		return []NACKAction{{PLI: true}}
	}

	// A newer packet: open a gap for every skipped sequence number, count it
	// as "newer" on every open gap (including the ones just opened), and
	// clear this seq if it was itself tracked.
	for missing := s.highestSeq + 1; missing != seq; missing++ {
		if _, tracked := s.gaps[missing]; !tracked && len(s.gaps) < s.cfg.MaxGaps {
			s.gaps[missing] = &nackGap{firstSeenNs: nowNs}
		}
	}
	for _, gap := range s.gaps {
		gap.newerSeen++
	}
	delete(s.gaps, seq)
	s.highestSeq = seq
	return s.evaluate(nowNs)
}

// Tick is the time-driven re-evaluation with no new packet, so a gap that
// stops seeing newer traffic still ages out to its re-NACK or PLI.
func (s *NACKScheduler) Tick(nowNs uint64) []NACKAction {
	return s.evaluate(nowNs)
}

// CancelGap removes a tracked gap WITHOUT the straggler path's RTT-sample
// side effect. Used when FEC reconstructs the missing packet after a NACK
// already went out: sampling "time since NACK" there would inject FEC latency
// — not a network round trip — into the RTT estimate. No-op for an untracked
// sequence number.
func (s *NACKScheduler) CancelGap(seq uint16) {
	delete(s.gaps, seq)
}

// NoteRecovered accounts for one FEC-recovered packet: its gap clears with no
// RTT sample (like CancelGap), and when the recovered seq is AHEAD of the
// highest wire packet — the tail-of-batch marker case, where no wire packet
// ever carries that seq — the cursor advances past it. Without the advance,
// the next batch's first packet would re-open a phantom gap for the
// already-recovered seq and burn a spurious NACK. Sequence numbers genuinely
// skipped between the old highest and the recovery still open gaps.
func (s *NACKScheduler) NoteRecovered(seq uint16, nowNs uint64) {
	delete(s.gaps, seq)
	if !s.hasHighest {
		return
	}
	forward := seq - s.highestSeq
	if forward == 0 || forward > 1<<15 {
		return // behind or duplicate — nothing to advance
	}
	// A recovery is always adjacent to received group members, so a jump
	// wider than the gap budget cannot be a real recovery — leave it to
	// Observe's discontinuity path rather than mass-opening gaps.
	if int(forward) > s.cfg.MaxGaps {
		return
	}
	for missing := s.highestSeq + 1; missing != seq; missing++ {
		if _, tracked := s.gaps[missing]; !tracked && len(s.gaps) < s.cfg.MaxGaps {
			s.gaps[missing] = &nackGap{firstSeenNs: nowNs}
		}
	}
	for _, gap := range s.gaps {
		gap.newerSeen++
	}
	s.highestSeq = seq
}

// updateRTTSample blends one NACK→retransmit round trip into the estimate:
// an EMA of 7/8 old + 1/8 new, clamped to a sane band.
func (s *NACKScheduler) updateRTTSample(sampleNs uint64) {
	clamped := sampleNs
	if clamped < 1_000_000 {
		clamped = 1_000_000
	}
	if clamped > 2_000_000_000 {
		clamped = 2_000_000_000
	}
	s.rttNs = (s.rttNs*7 + clamped) / 8
}

// evaluate is the decision pass shared by Observe and Tick: batch every
// eligible gap into one datagram (under the rate cap), abandon exhausted or
// aged gaps to a single PLI.
func (s *NACKScheduler) evaluate(nowNs uint64) []NACKAction {
	var toNack []uint16
	abandon := false
	reNackInterval := s.rttNs + s.rttNs/2
	if reNackInterval < s.cfg.ReNackFloorNs {
		reNackInterval = s.cfg.ReNackFloorNs
	}

	for seq, gap := range s.gaps {
		agedOut := nowNs-gap.firstSeenNs >= s.cfg.RingWindowNs
		if agedOut || gap.attempts >= s.cfg.MaxAttempts {
			delete(s.gaps, seq)
			abandon = true
			continue
		}
		ageEligible := nowNs-gap.firstSeenNs >= s.cfg.ReorderToleranceNs
		countEligible := gap.newerSeen >= s.cfg.ReorderPacketTolerance
		if !ageEligible && !countEligible {
			continue
		}
		if gap.attempts == 0 || nowNs-gap.lastNackNs >= reNackInterval {
			toNack = append(toNack, seq)
		}
	}

	var actions []NACKAction
	if len(toNack) > 0 && s.rateAllows(nowNs) {
		// Only the seqs that fit one capped NACK datagram (≤16 FCI entries)
		// go on the wire — and only those count as attempted. Otherwise the
		// tail beyond 16 groups would silently burn its attempts without ever
		// being sent and hit a premature PLI.
		onWire := FCICappedSeqs(toNack, 16)
		for _, seq := range onWire {
			if gap, ok := s.gaps[seq]; ok {
				gap.attempts++
				gap.lastNackNs = nowNs
			}
		}
		s.nackStampsNs = append(s.nackStampsNs, nowNs)
		actions = append(actions, NACKAction{Seqs: onWire})
	}
	if abandon {
		actions = append(actions, NACKAction{PLI: true})
	}
	return actions
}

// rateAllows enforces the per-second NACK-datagram cap, pruning stamps older
// than one second.
func (s *NACKScheduler) rateAllows(nowNs uint64) bool {
	kept := s.nackStampsNs[:0]
	for _, stamp := range s.nackStampsNs {
		if nowNs-stamp <= 1_000_000_000 {
			kept = append(kept, stamp)
		}
	}
	s.nackStampsNs = kept
	return len(s.nackStampsNs) < s.cfg.MaxNacksPerSecond
}

// FCICappedSeqs is the subset of seqs that fits in maxEntries generic-NACK
// FCI groups — exactly what one capped NACK datagram carries (TS-NCK-001).
// Greedy over numerically sorted seqs, mirroring PackFCI, so the scheduler
// counts only on-the-wire seqs as attempted.
func FCICappedSeqs(seqs []uint16, maxEntries int) []uint16 {
	sorted := append([]uint16(nil), seqs...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })

	var covered []uint16
	entries := 0
	for i := 0; i < len(sorted) && entries < maxEntries; {
		pid := sorted[i]
		covered = append(covered, pid)
		j := i + 1
		for j < len(sorted) {
			delta := sorted[j] - pid
			if delta < 1 || delta > 16 {
				break
			}
			covered = append(covered, sorted[j])
			j++
		}
		i = j
		entries++
	}
	return covered
}

// PackFCI packs missing sequence numbers into generic-NACK (pid, blp) FCI
// entries: each pid is a base seq, blp a bitmask of the 16 following it
// (spec §9.1).
//
// The sort is plain numeric, deliberately NOT wrap-aware — a gap set spanning
// the 16-bit boundary splits into two groups instead of one. That is an
// efficiency wart, not a correctness bug (every seq is still covered, and the
// receiver's lookup is per-seq), and the Swift implementation pins the same
// behavior; a wrap-aware "fix" on one side only would be a differential
// divergence.
func PackFCI(seqs []uint16) []NACKEntry {
	sorted := append([]uint16(nil), seqs...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })

	var entries []NACKEntry
	for i := 0; i < len(sorted); {
		pid := sorted[i]
		var blp uint16
		j := i + 1
		for j < len(sorted) {
			delta := sorted[j] - pid
			if delta < 1 || delta > 16 {
				break
			}
			blp |= 1 << (delta - 1)
			j++
		}
		entries = append(entries, NACKEntry{PID: pid, BLP: blp})
		i = j
	}
	return entries
}
