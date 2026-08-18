package tailscreen

import "testing"

// Ported from the Swift suite's RRAccountingTests — the viewer's receiver-
// report bookkeeping, with the baseline and duplicate fixes pinned. Every
// expected Q8 fraction and extended-seq value matches the Swift assertions
// constant for constant.

func rrMustReport(t *testing.T, acc *RRAccounting) (fracLostQ8 uint8, extHighestSeq uint32) {
	t.Helper()
	frac, ext, ok := acc.MakeReport()
	if !ok {
		t.Fatal("expected a report")
	}
	return frac, ext
}

func TestRRNoReportBeforeFirstPacket(t *testing.T) {
	acc := NewRRAccounting()
	if acc.HasBaseline() {
		t.Fatal("no packet observed — must not have a baseline")
	}
	if _, _, ok := acc.MakeReport(); ok {
		t.Fatal("no packet observed — must not report")
	}
}

func TestRRBaselineIntervalCountsFirstPacketInBothLegs(t *testing.T) {
	// The historical defect: N in-order packets yielded expected = N−1,
	// received = N, so one real loss in the first interval was masked.
	acc := NewRRAccounting()
	for seq := 0; seq < 10; seq++ {
		acc.Observe(uint16(seq))
	}
	frac, ext := rrMustReport(t, acc)
	if frac != 0 {
		t.Fatalf("10 packets, no loss → zero fraction lost, got %d", frac)
	}
	if ext != 9 {
		t.Fatalf("extHighestSeq = %d, want 9", ext)
	}
}

func TestRRSingleLossInFirstIntervalIsReported(t *testing.T) {
	acc := NewRRAccounting()
	for _, seq := range []uint16{0, 1, 2, 3, 4, 6, 7, 8, 9} { // 5 lost
		acc.Observe(seq)
	}
	frac, _ := rrMustReport(t, acc)
	// expected = 10, received = 9 → 1 × 256 / 10 = 25 (Q8 ≈ 10 %).
	if frac != 25 {
		t.Fatalf("one loss out of ten must not be masked: frac = %d, want 25", frac)
	}
}

func TestRRDuplicatesDoNotInflateReceived(t *testing.T) {
	acc := NewRRAccounting()
	for _, seq := range []uint16{0, 1, 2, 3, 4, 6, 7, 8, 9} {
		acc.Observe(seq)
		acc.Observe(seq) // every packet duplicated
	}
	frac, _ := rrMustReport(t, acc)
	if frac != 25 {
		t.Fatalf("duplicates must not count as received — they'd mask the real loss: frac = %d, want 25", frac)
	}
}

func TestRRServedRetransmitCountsOnceAsReceived(t *testing.T) {
	acc := NewRRAccounting()
	acc.Observe(0)
	acc.Observe(1)
	acc.Observe(3) // 2 missing
	acc.Observe(4)
	acc.Observe(2) // NACK retransmit lands: first arrival, counts
	acc.Observe(2) // …but the duplicate of it doesn't
	frac, ext := rrMustReport(t, acc)
	if frac != 0 {
		t.Fatalf("a served retransmit is recovered loss, not loss: frac = %d", frac)
	}
	if ext != 4 {
		t.Fatalf("extHighestSeq = %d, want 4", ext)
	}
}

func TestRRWrapAcross65535ExtendsSequenceSpace(t *testing.T) {
	acc := NewRRAccounting()
	for _, seq := range []uint16{65530, 65531, 65532, 65533, 65534, 65535} {
		acc.Observe(seq)
	}
	for seq := 0; seq <= 4; seq++ {
		acc.Observe(uint16(seq))
	}
	frac, ext := rrMustReport(t, acc)
	if frac != 0 {
		t.Fatalf("a clean wrap is not loss: frac = %d", frac)
	}
	if want := uint32(1<<16 | 4); ext != want {
		t.Fatalf("extended highest must carry the cycle count (RFC 3550 form): got %d, want %d", ext, want)
	}
}

func TestRRLossAcrossTheWrapIsReported(t *testing.T) {
	acc := NewRRAccounting()
	acc.Observe(65534)
	acc.Observe(65535)
	// 0 and 1 lost across the boundary.
	acc.Observe(2)
	acc.Observe(3)
	frac, _ := rrMustReport(t, acc)
	// expected = 6, received = 4 → 2 × 256 / 6 = 85.
	if frac != 85 {
		t.Fatalf("frac = %d, want 85", frac)
	}
}

func TestRRFirstSeqZeroDoesNotUnderflow(t *testing.T) {
	// The baseline is extFirst − 1, which for seq 0 must go to −1, not wrap.
	acc := NewRRAccounting()
	acc.Observe(0)
	frac, ext := rrMustReport(t, acc)
	if frac != 0 || ext != 0 {
		t.Fatalf("frac = %d, ext = %d, want 0, 0", frac, ext)
	}
}

func TestRRSecondIntervalStartsFromNewBaseline(t *testing.T) {
	acc := NewRRAccounting()
	for seq := 0; seq < 10; seq++ {
		acc.Observe(uint16(seq))
	}
	rrMustReport(t, acc)
	// Second interval: 4 of 5 arrive.
	for _, seq := range []uint16{10, 11, 13, 14} {
		acc.Observe(seq)
	}
	frac, ext := rrMustReport(t, acc)
	// expected = 5 (10…14), received = 4 → 1 × 256 / 5 = 51.
	if frac != 51 {
		t.Fatalf("frac = %d, want 51", frac)
	}
	if ext != 14 {
		t.Fatalf("extHighestSeq = %d, want 14", ext)
	}
}

func TestRRStragglerOlderThanWindowIsIgnored(t *testing.T) {
	acc := NewRRAccounting()
	acc.Observe(5000)
	// 500 is outside the 4096-packet dedupe window behind 5000; its window
	// slot belongs to a newer seq, so it must not count.
	acc.Observe(500)
	frac, ext := rrMustReport(t, acc)
	if ext != 5000 {
		t.Fatalf("extHighestSeq = %d, want 5000", ext)
	}
	if frac != 0 {
		t.Fatalf("expected = received = 1 (baseline only): frac = %d", frac)
	}
}

func TestRRPreSessionStragglerIsIgnored(t *testing.T) {
	acc := NewRRAccounting()
	acc.Observe(5)     // ext 5
	acc.Observe(65533) // extends to −3: precedes the session
	frac, ext := rrMustReport(t, acc)
	if ext != 5 {
		t.Fatalf("extHighestSeq = %d, want 5", ext)
	}
	if frac != 0 {
		t.Fatalf("frac = %d, want 0", frac)
	}
}

func TestRRExtendPicksNearestCycle(t *testing.T) {
	cases := []struct {
		seq  uint16
		near int64
		want int64
	}{
		{2, 65535, 65538},
		{65533, 65538, 65533},
		{100, 100, 100},
		{65533, 5, -3},
	}
	for _, c := range cases {
		if got := ExtendSeq(c.seq, c.near); got != c.want {
			t.Errorf("ExtendSeq(%d, %d) = %d, want %d", c.seq, c.near, got, c.want)
		}
	}
}

func TestRRWindowLapClearsStaleSeenBits(t *testing.T) {
	// A seq whose window slot was used a lap ago must still count as a
	// first arrival after the window advances past the old occupant.
	acc := NewRRAccounting()
	acc.Observe(0)
	acc.MakeReport()
	// Jump forward exactly one window: seq 4096 maps to slot 0 (same as
	// seq 0). Without the range-clear it would read as "already seen".
	acc.Observe(uint16(DedupeWindowBits))
	frac, ext := rrMustReport(t, acc)
	// expected = 4096 (1…4096), received = 1 → heavy loss, but the key
	// point is the arrival was COUNTED (received = 1, not 0):
	// lost = 4095 → 4095 × 256 / 4096 = 255.
	if frac != 255 {
		t.Fatalf("frac = %d, want 255", frac)
	}
	if ext != uint32(DedupeWindowBits) {
		t.Fatalf("extHighestSeq = %d, want %d", ext, DedupeWindowBits)
	}
}

func TestRRLateFillBeyondOldWindowStillCounts(t *testing.T) {
	// The dedupe window must cover the server's retransmit horizon: a
	// served NACK fill can land far behind highest at high bitrates. Here
	// 20 packets go missing, the stream runs ~1900 packets past them, and
	// the retransmits then arrive >1024 behind highest — under a 1024-packet
	// window they were ignored (counted as lost); under the 4096 window
	// they count and the interval reports clean.
	acc := NewRRAccounting()
	for seq := 0; seq < 100; seq++ {
		acc.Observe(uint16(seq))
	}
	for seq := 120; seq < 2048; seq++ { // 100…119 lost in transit
		acc.Observe(uint16(seq))
	}
	for seq := 100; seq < 120; seq++ { // …and served by retransmission, late
		acc.Observe(uint16(seq))
	}
	frac, ext := rrMustReport(t, acc)
	if frac != 0 {
		t.Fatalf("late fills within the window must count as received: frac = %d", frac)
	}
	if ext != 2047 {
		t.Fatalf("extHighestSeq = %d, want 2047", ext)
	}
}
