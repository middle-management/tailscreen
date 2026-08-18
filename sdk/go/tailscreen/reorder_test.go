package tailscreen

import "testing"

// These cases are ported from the Swift suite's own reorder-buffer tests,
// assertion for assertion and constant for constant. Reproducing the same
// numbers here is the strongest check available before the differential
// target runs both implementations against each other: a port that merely
// looks right passes nothing, and one that returns 101 releases where Swift
// returns 101 has almost certainly got the sequence arithmetic right too.

func TestReorderCountBasedWindowTearsOnDeepPileup(t *testing.T) {
	// The behaviour that made a keyframe unrecoverable: a count window
	// overflows in tens of milliseconds at video bitrate, so the gap is
	// abandoned long before a retransmit could arrive.
	buf := NewReorderBuffer(64, 0)
	if got := buf.Push(100, []byte{0}, 0); len(got) != 1 {
		t.Fatalf("first packet released %d, want 1", len(got))
	}

	torn := false
	for seq := 102; seq <= 201; seq++ {
		for _, release := range buf.Push(uint16(seq), []byte{byte(seq)}, 0) {
			if release.LostBefore {
				torn = true
			}
		}
	}
	if !torn {
		t.Fatal("a count-based window must tear on a deep pileup")
	}
}

func TestReorderTimeHeldGapSurvivesUntilTheRetransmit(t *testing.T) {
	const t0 uint64 = 1_000_000_000
	buf := NewReorderBuffer(512, 250_000_000)

	if got := buf.Push(100, []byte{0}, t0); len(got) != 1 {
		t.Fatalf("first packet released %d, want 1", len(got))
	}

	// A hundred packets pile up behind the gap at 101, ~0.3 ms apart, so the
	// whole pileup lands within ~30 ms — far inside the 250 ms hold.
	for i, seq := 0, 102; seq <= 201; i, seq = i+1, seq+1 {
		got := buf.Push(uint16(seq), []byte{byte(seq)}, t0+uint64(i)*300_000)
		if len(got) != 0 {
			t.Fatalf("seq %d released %d packets; the gap must be held", seq, len(got))
		}
	}

	// The retransmit of 101 lands ~160 ms later, inside the hold.
	filled := buf.Push(101, []byte{101}, t0+160_000_000)
	if len(filled) != 101 {
		t.Fatalf("released %d packets on the fill, want 101 (seq 101…201 in order)", len(filled))
	}
	for _, release := range filled {
		if release.LostBefore {
			t.Fatal("no loss should be declared — the frame stays whole")
		}
	}
	if got := buf.SkippedGapCount(); got != 0 {
		t.Fatalf("skipped %d gaps, want 0", got)
	}
}

func TestReorderTimeHeldGapIsStillAbandonedAfterTheDeadline(t *testing.T) {
	// The hold is bounded: a retransmit that never comes must not wedge the
	// stream forever.
	const t0 uint64 = 1_000_000_000
	buf := NewReorderBuffer(512, 200_000_000)

	if got := buf.Push(10, []byte{10}, t0); len(got) != 1 {
		t.Fatalf("first packet released %d, want 1", len(got))
	}
	if got := buf.Push(12, []byte{12}, t0); len(got) != 0 {
		t.Fatalf("seq 12 released %d packets; the gap at 11 must be held", len(got))
	}

	releases := buf.Push(13, []byte{13}, t0+250_000_000)
	if len(releases) == 0 || !releases[0].LostBefore {
		t.Fatalf("the gap must be abandoned once the hold expires, got %+v", releases)
	}
	if got := buf.SkippedGapCount(); got != 1 {
		t.Fatalf("skipped %d gaps, want 1", got)
	}
}

func TestReorderReleasesInOrderAndFillsGaps(t *testing.T) {
	buf := NewReorderBuffer(16, 0)
	buf.Push(1, []byte{1}, 0)

	// 3 arrives before 2 and is held; 2 then releases both, in order.
	if got := buf.Push(3, []byte{3}, 0); len(got) != 0 {
		t.Fatalf("out-of-order packet released %d, want 0", len(got))
	}
	got := buf.Push(2, []byte{2}, 0)
	if len(got) != 2 || got[0].Packet[0] != 2 || got[1].Packet[0] != 3 {
		t.Fatalf("gap fill released %+v, want packets 2 then 3", got)
	}
	for _, release := range got {
		if release.LostBefore {
			t.Fatal("reordering alone must never be reported as loss")
		}
	}
}

func TestReorderDropsDuplicatesAndStragglers(t *testing.T) {
	buf := NewReorderBuffer(16, 0)
	buf.Push(5, []byte{5}, 0)
	buf.Push(6, []byte{6}, 0)

	if got := buf.Push(6, []byte{6}, 0); len(got) != 0 {
		t.Fatalf("a duplicate released %d packets, want 0", len(got))
	}
	if got := buf.Push(5, []byte{5}, 0); len(got) != 0 {
		t.Fatalf("a straggler released %d packets, want 0", len(got))
	}
	if got := buf.SkippedGapCount(); got != 0 {
		t.Fatalf("a duplicate must not count as a skipped gap, got %d", got)
	}
}

func TestReorderSurvivesSequenceWrap(t *testing.T) {
	buf := NewReorderBuffer(16, 0)
	buf.Push(65534, []byte{1}, 0)

	// 0 arrives before 65535: the distance must be computed mod 2^16, or 0
	// looks like a straggler ~65k behind rather than the next-but-one packet.
	if got := buf.Push(0, []byte{3}, 0); len(got) != 0 {
		t.Fatalf("packet past the wrap released %d, want 0 (held)", len(got))
	}
	got := buf.Push(65535, []byte{2}, 0)
	if len(got) != 2 || got[0].Packet[0] != 2 || got[1].Packet[0] != 3 {
		t.Fatalf("released %+v across the wrap, want packets 2 then 3", got)
	}
}

func TestReorderMemoryCapWinsOverTheTimeHold(t *testing.T) {
	// The cap is not advisory: a loss storm must not grow the buffer without
	// bound however long the hold has left to run.
	const t0 uint64 = 1_000_000_000
	buf := NewReorderBuffer(4, 10_000_000_000) // a hold far longer than the test
	buf.Push(1, []byte{1}, t0)

	var released []ReorderRelease
	for seq := 3; seq <= 8; seq++ {
		released = append(released, buf.Push(uint16(seq), []byte{byte(seq)}, t0)...)
	}
	if len(released) == 0 {
		t.Fatal("the memory cap must abandon the gap even inside the hold")
	}
	if !released[0].LostBefore {
		t.Fatal("the packet after an abandoned gap must be marked")
	}
}
