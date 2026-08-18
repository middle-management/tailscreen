package tailscreen

import (
	"sort"
	"testing"
)

// Ported from the Swift suite's NACKSchedulerTests, case for case and
// constant for constant — including the EMA arithmetic down to the
// nanosecond and the pinned non-wrap-aware PackFCI split. Reproducing the
// Swift numbers exactly is the pre-differential check that the two
// schedulers make the same decisions.

const (
	nsMs uint64 = 1_000_000
	nsS  uint64 = 1_000_000_000
)

func defaultScheduler() *NACKScheduler {
	return NewNACKScheduler(NACKSchedulerConfig{})
}

func expectNACK(t *testing.T, actions []NACKAction, want []uint16) {
	t.Helper()
	if len(actions) != 1 || actions[0].PLI || len(actions[0].Seqs) == 0 {
		t.Fatalf("expected exactly one NACK action, got %+v", actions)
	}
	got := append([]uint16(nil), actions[0].Seqs...)
	if len(got) != len(want) {
		t.Fatalf("NACK covers %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("NACK covers %v, want %v", got, want)
		}
	}
}

func expectPLI(t *testing.T, actions []NACKAction) {
	t.Helper()
	if len(actions) != 1 || !actions[0].PLI {
		t.Fatalf("expected exactly one PLI action, got %+v", actions)
	}
}

func expectEmpty(t *testing.T, actions []NACKAction, what string) {
	t.Helper()
	if len(actions) != 0 {
		t.Fatalf("%s: expected no actions, got %+v", what, actions)
	}
}

func TestSchedulerFirstPacketOpensNoGap(t *testing.T) {
	s := defaultScheduler()
	expectEmpty(t, s.Observe(100, 0), "first packet")
	if s.HasOpenGaps() {
		t.Fatal("no gap should be tracked after the first packet")
	}
}

func TestSchedulerPureReorderProducesNoNACKs(t *testing.T) {
	// 100, 102, 101 inside the tolerance: the reordered gap fills before it
	// is eligible. Zero NACKs, zero PLIs (TS-NCK-007).
	s := defaultScheduler()
	expectEmpty(t, s.Observe(100, 0), "seq 100")
	expectEmpty(t, s.Observe(102, 1*nsMs), "seq 102")
	expectEmpty(t, s.Observe(101, 2*nsMs), "seq 101")
	if s.HasOpenGaps() {
		t.Fatal("the reordered gap should have filled")
	}
}

func TestSchedulerGenuineLossNACKsAfterToleranceThenPLIs(t *testing.T) {
	s := NewNACKScheduler(NACKSchedulerConfig{InitialRTTNs: 60_000_000}) // reNack = 90 ms
	expectEmpty(t, s.Observe(0, 0), "seq 0")
	expectEmpty(t, s.Observe(5, 0), "seq 5 — gaps 1…4 inside tolerance")
	expectNACK(t, s.Tick(20*nsMs), []uint16{1, 2, 3, 4})
	expectEmpty(t, s.Tick(40*nsMs), "not due to re-NACK yet")
	expectNACK(t, s.Tick(120*nsMs), []uint16{1, 2, 3, 4})
	expectNACK(t, s.Tick(220*nsMs), []uint16{1, 2, 3, 4})
	expectPLI(t, s.Tick(320*nsMs)) // attempts exhausted
	if s.HasOpenGaps() {
		t.Fatal("abandoned gaps must not stay tracked")
	}
}

func TestSchedulerGapAgedPastRingWindowFallsBackToPLI(t *testing.T) {
	s := defaultScheduler()
	s.Observe(0, 0)
	s.Observe(3, 0) // gaps 1, 2
	expectPLI(t, s.Tick(1100*nsMs))
	if s.HasOpenGaps() {
		t.Fatal("aged-out gaps must not stay tracked")
	}
}

func TestSchedulerRetransmitFillsGapNoPLI(t *testing.T) {
	s := defaultScheduler()
	s.Observe(0, 0)
	s.Observe(3, 0)
	expectEmpty(t, s.Observe(1, 5*nsMs), "retransmit of 1")
	expectEmpty(t, s.Observe(2, 6*nsMs), "retransmit of 2")
	if s.HasOpenGaps() {
		t.Fatal("filled gaps must clear")
	}
	expectEmpty(t, s.Tick(500*nsMs), "nothing left to abandon")
}

func TestSchedulerServedRetransmitCountsAsRecovery(t *testing.T) {
	s := defaultScheduler()
	s.Observe(0, 0)
	s.Observe(2, 0)
	expectNACK(t, s.Tick(20*nsMs), []uint16{1})
	s.Observe(1, 200*nsMs) // the retransmit fills it
	if got := s.DrainNackRecovered(); got != 1 {
		t.Fatalf("drained %d recoveries, want 1", got)
	}
	if got := s.DrainNackRecovered(); got != 0 {
		t.Fatalf("drain must read-and-reset, second read gave %d", got)
	}
}

func TestSchedulerReorderFillIsNotARecovery(t *testing.T) {
	// A gap that fills before any NACK fired was never a link loss and must
	// not inflate the raw-loss signal.
	s := defaultScheduler()
	s.Observe(0, 0)
	s.Observe(2, 0)
	s.Observe(1, 5*nsMs)
	if got := s.DrainNackRecovered(); got != 0 {
		t.Fatalf("a reorder fill counted as %d recoveries, want 0", got)
	}
}

func TestSchedulerPacketCountToleranceMakesGapEligibleEarly(t *testing.T) {
	s := defaultScheduler()
	s.Observe(0, 0)
	s.Observe(2, 0)      // gap 1, newerSeen 1
	s.Observe(3, 1*nsMs) // newerSeen 2
	expectNACK(t, s.Observe(4, 2*nsMs), []uint16{1})
}

func TestSchedulerRTTWidensReNackInterval(t *testing.T) {
	slow := NewNACKScheduler(NACKSchedulerConfig{InitialRTTNs: 400_000_000}) // reNack = 600 ms
	slow.Observe(0, 0)
	slow.Observe(2, 0)
	expectNACK(t, slow.Tick(20*nsMs), []uint16{1})
	expectEmpty(t, slow.Tick(300*nsMs), "a 400 ms-RTT scheduler holds where a 60 ms one would re-NACK")
	expectNACK(t, slow.Tick(640*nsMs), []uint16{1})
}

func TestSchedulerFCICappedSeqsBoundsToSixteenGroups(t *testing.T) {
	seqs := make([]uint16, 20)
	for i := range seqs {
		seqs[i] = uint16(i * 20) // isolated — one group each
	}
	capped := FCICappedSeqs(seqs, 16)
	if len(capped) != 16 {
		t.Fatalf("capped to %d seqs, want 16", len(capped))
	}
	for i, seq := range capped {
		if seq != seqs[i] {
			t.Fatalf("capped[%d] = %d, want %d", i, seq, seqs[i])
		}
	}
}

func TestSchedulerFCICappedSeqsKeepsContiguousRun(t *testing.T) {
	seqs := make([]uint16, 30)
	for i := range seqs {
		seqs[i] = uint16(i)
	}
	got := FCICappedSeqs(seqs, 16)
	if len(got) != 30 {
		t.Fatalf("a dense run must fit under the cap in full, got %d of 30", len(got))
	}
}

func TestSchedulerContiguousGapRunFullyNACKed(t *testing.T) {
	s := defaultScheduler()
	s.Observe(0, 0)
	s.Observe(51, 0) // gaps 1…50
	actions := s.Tick(20 * nsMs)
	if len(actions) != 1 || actions[0].PLI {
		t.Fatalf("a repairable run must NACK, not PLI: %+v", actions)
	}
	got := append([]uint16(nil), actions[0].Seqs...)
	sort.Slice(got, func(i, j int) bool { return got[i] < got[j] })
	if len(got) != 50 || got[0] != 1 || got[49] != 50 {
		t.Fatalf("NACK covers %d seqs [%d…%d], want all of 1…50", len(got), got[0], got[len(got)-1])
	}
}

func TestSchedulerLargeSeqJumpFallsBackToPLI(t *testing.T) {
	s := defaultScheduler()
	s.Observe(0, 0)
	expectPLI(t, s.Observe(300, 1*nsMs))
	if s.HasOpenGaps() {
		t.Fatal("a discontinuity must not leave tracked gaps")
	}
}

func TestSchedulerRTTAdaptsFromRetransmitRoundTrip(t *testing.T) {
	s := NewNACKScheduler(NACKSchedulerConfig{InitialRTTNs: 60_000_000})
	if got := s.RTTEstimateNs(); got != 60_000_000 {
		t.Fatalf("seed RTT %d, want 60 ms", got)
	}
	s.Observe(0, 0)
	s.Observe(2, 0)
	expectNACK(t, s.Tick(20*nsMs), []uint16{1})
	s.Observe(1, 120*nsMs) // retransmit 100 ms after the NACK
	// EMA: (60·7 + 100) / 8 = 65 ms.
	if got := s.RTTEstimateNs(); got != 65_000_000 {
		t.Fatalf("RTT after one 100 ms sample = %d, want 65 ms", got)
	}
}

func TestSchedulerCancelGapClearsWithoutRTTSampleOrPLI(t *testing.T) {
	s := NewNACKScheduler(NACKSchedulerConfig{InitialRTTNs: 60_000_000})
	s.Observe(0, 0)
	s.Observe(2, 0)
	expectNACK(t, s.Tick(20*nsMs), []uint16{1})
	s.CancelGap(1)
	if s.HasOpenGaps() {
		t.Fatal("cancelled gap must clear")
	}
	if got := s.RTTEstimateNs(); got != 60_000_000 {
		t.Fatalf("CancelGap fed the RTT estimate: %d", got)
	}
	expectEmpty(t, s.Tick(2*nsS), "no re-NACK and no PLI after cancel")
}

func TestSchedulerCancelGapBeforeAnyNACKSuppressesIt(t *testing.T) {
	s := defaultScheduler()
	s.Observe(0, 0)
	s.Observe(2, 1*nsMs)
	s.CancelGap(1)
	expectEmpty(t, s.Tick(500*nsMs), "cancelled inside the tolerance")
	if s.HasOpenGaps() {
		t.Fatal("no gap should remain")
	}
}

func TestSchedulerCancelGapUntrackedSeqIsANoOp(t *testing.T) {
	s := defaultScheduler()
	s.Observe(0, 0)
	s.CancelGap(42)
	if s.HasOpenGaps() {
		t.Fatal("cancelling an untracked seq must change nothing")
	}
}

func TestSchedulerNoteRecoveredAdvancesPastTailOfBatchLoss(t *testing.T) {
	// The marker packet is lost and FEC-recovered: the recovered seq is AHEAD
	// of every wire packet, so without a cursor advance the next batch's
	// first packet would re-open a phantom gap and burn a spurious NACK.
	s := defaultScheduler()
	for seq := 0; seq <= 8; seq++ {
		s.Observe(uint16(seq), uint64(seq)*nsMs)
	}
	s.NoteRecovered(9, 10*nsMs)
	if s.HasOpenGaps() {
		t.Fatal("recovery must not leave gaps")
	}
	expectEmpty(t, s.Observe(10, 11*nsMs), "next batch is contiguous with the recovery")
	if s.HasOpenGaps() {
		t.Fatal("no phantom gap for the recovered seq")
	}
	expectEmpty(t, s.Tick(2*nsS), "nothing to abandon, ever")
}

func TestSchedulerNoteRecoveredClearsGapWithoutRTTSample(t *testing.T) {
	s := NewNACKScheduler(NACKSchedulerConfig{InitialRTTNs: 60_000_000})
	s.Observe(0, 0)
	s.Observe(2, 0)
	expectNACK(t, s.Tick(20*nsMs), []uint16{1})
	s.NoteRecovered(1, 30*nsMs)
	if s.HasOpenGaps() {
		t.Fatal("recovered gap must clear")
	}
	if got := s.RTTEstimateNs(); got != 60_000_000 {
		t.Fatalf("recovery latency fed the RTT EMA: %d", got)
	}
	expectEmpty(t, s.Tick(2*nsS), "no PLI after recovery")
}

func TestSchedulerNoteRecoveredOpensGapsForGenuinelySkippedSeqs(t *testing.T) {
	s := defaultScheduler()
	s.Observe(0, 0)
	s.NoteRecovered(2, 1*nsMs)
	if !s.HasOpenGaps() {
		t.Fatal("seq 1 is genuinely missing and must be tracked")
	}
	expectNACK(t, s.Tick(30*nsMs), []uint16{1})
}

// The FEC-mode tolerances, as TransportTuning defines them on the Swift
// side: fecGroupSizeLight + 2 packets, 25 ms.
const (
	fecSchedulerPacketTolerance = 12
	fecSchedulerToleranceNs     = 25_000_000
)

func TestSchedulerSetReorderTolerancesSwitchesInPlace(t *testing.T) {
	s := NewNACKScheduler(NACKSchedulerConfig{InitialRTTNs: 60_000_000})
	s.Observe(0, 0)
	s.Observe(2, 0) // gap 1, newerSeen 1
	s.SetReorderTolerances(fecSchedulerToleranceNs, fecSchedulerPacketTolerance)
	expectEmpty(t, s.Tick(20*nsMs), "20 ms is inside the relaxed 25 ms tolerance")
	s.SetReorderTolerances(DefaultReorderToleranceNs, DefaultReorderPacketTolerance)
	expectNACK(t, s.Tick(21*nsMs), []uint16{1})
	if got := s.RTTEstimateNs(); got != 60_000_000 {
		t.Fatalf("switching tolerances must not touch the RTT estimate: %d", got)
	}
}

func TestSchedulerFECModeTolerancesDelayNACKUntilBeyondGroupSpan(t *testing.T) {
	s := NewNACKScheduler(NACKSchedulerConfig{
		ReorderToleranceNs:     fecSchedulerToleranceNs,
		ReorderPacketTolerance: fecSchedulerPacketTolerance,
	})
	s.Observe(0, 0)
	s.Observe(2, 0) // gap 1, newerSeen 1
	var actions []NACKAction
	for i := 0; i < 11; i++ {
		if len(actions) != 0 {
			t.Fatalf("NACK fired early at newerSeen %d: %+v", i+1, actions)
		}
		actions = s.Observe(uint16(3+i), uint64(i)*nsMs)
	}
	expectNACK(t, actions, []uint16{1})
}

func TestSchedulerFECModeTimeToleranceIs25ms(t *testing.T) {
	s := NewNACKScheduler(NACKSchedulerConfig{
		ReorderToleranceNs:     fecSchedulerToleranceNs,
		ReorderPacketTolerance: fecSchedulerPacketTolerance,
	})
	s.Observe(0, 0)
	s.Observe(2, 0)
	expectEmpty(t, s.Tick(24*nsMs), "under the 25 ms FEC slack")
	expectNACK(t, s.Tick(25*nsMs), []uint16{1})
}

func TestSchedulerFCIPacking(t *testing.T) {
	single := PackFCI([]uint16{1, 2, 3, 4})
	if len(single) != 1 || single[0].PID != 1 || single[0].BLP != 0b0111 {
		t.Fatalf("contiguous run packed as %+v, want one entry pid=1 blp=0b0111", single)
	}
	split := PackFCI([]uint16{1, 20})
	if len(split) != 2 || split[0].PID != 1 || split[0].BLP != 0 || split[1].PID != 20 || split[1].BLP != 0 {
		t.Fatalf("wide gap packed as %+v, want two zero-mask entries", split)
	}
}

// --- sequence wraparound (65535 → 0) ---------------------------------------

func TestSchedulerGapAcrossWrapIsTrackedAndNACKed(t *testing.T) {
	s := defaultScheduler()
	expectEmpty(t, s.Observe(65534, 0), "seq 65534")
	expectEmpty(t, s.Observe(2, 0), "seq 2 — gaps {65535, 0, 1}")
	if !s.HasOpenGaps() {
		t.Fatal("wrap-spanning gaps must be tracked")
	}
	// FCICappedSeqs sorts numerically, so the datagram covers [0, 1, 65535].
	expectNACK(t, s.Tick(20*nsMs), []uint16{0, 1, 65535})
}

func TestSchedulerStragglerAcrossWrapFillsGapAndFeedsRTT(t *testing.T) {
	s := NewNACKScheduler(NACKSchedulerConfig{InitialRTTNs: 60_000_000})
	s.Observe(65534, 0)
	s.Observe(1, 0) // gaps {65535, 0}
	expectNACK(t, s.Tick(20*nsMs), []uint16{0, 65535})
	expectEmpty(t, s.Observe(65535, 60*nsMs), "retransmit across the wrap")
	expectEmpty(t, s.Observe(0, 60*nsMs), "second retransmit")
	if s.HasOpenGaps() {
		t.Fatal("both wrap-side gaps must clear")
	}
	// EMA after two 40 ms samples: 60 → 57.5 → 55.3125 ms.
	if got := s.RTTEstimateNs(); got != 55_312_500 {
		t.Fatalf("RTT after two 40 ms samples = %d, want 55312500", got)
	}
	expectEmpty(t, s.Tick(2*nsS), "no PLI later")
}

func TestSchedulerLargeSeqJumpAcrossWrapFallsBackToPLI(t *testing.T) {
	s := defaultScheduler()
	s.Observe(65530, 0)
	var jumped uint16 = 65530
	jumped += 300 // wraps to 294 — the discontinuity spans the boundary
	expectPLI(t, s.Observe(jumped, 1*nsMs))
	if s.HasOpenGaps() {
		t.Fatal("a wrap-spanning discontinuity must not leave gaps")
	}
}

func TestSchedulerPackFCIWrapPinsCurrentTwoGroupBehavior(t *testing.T) {
	// PINS CURRENT BEHAVIOR, matching Swift: the numeric sort is not
	// wrap-aware, so a wrap-spanning set splits into two groups. An
	// efficiency wart, not a correctness bug — every seq stays covered — and
	// "fixing" it on one side only would be a differential divergence.
	entries := PackFCI([]uint16{65534, 65535, 0, 1})
	if len(entries) != 2 {
		t.Fatalf("wrap-spanning set packed into %d groups, current behavior is 2", len(entries))
	}
	if entries[0].PID != 0 || entries[0].BLP != 0b1 {
		t.Fatalf("first group %+v, want pid=0 blp=0b1", entries[0])
	}
	if entries[1].PID != 65534 || entries[1].BLP != 0b1 {
		t.Fatalf("second group %+v, want pid=65534 blp=0b1", entries[1])
	}
	covered := map[uint16]bool{}
	for _, entry := range entries {
		for _, seq := range entry.Missing() {
			covered[seq] = true
		}
	}
	for _, want := range []uint16{65534, 65535, 0, 1} {
		if !covered[want] {
			t.Fatalf("seq %d dropped from coverage — the invariant that matters", want)
		}
	}
	if len(covered) != 4 {
		t.Fatalf("coverage is %v, want exactly the input set", covered)
	}
}

func TestSchedulerFCICappedSeqsWrapCoversEverySeq(t *testing.T) {
	onWire := FCICappedSeqs([]uint16{65534, 65535, 0, 1}, 16)
	covered := map[uint16]bool{}
	for _, seq := range onWire {
		covered[seq] = true
	}
	for _, want := range []uint16{65534, 65535, 0, 1} {
		if !covered[want] {
			t.Fatalf("seq %d silently dropped from the datagram", want)
		}
	}
}
