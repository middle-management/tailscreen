package tailscreen

import (
	"bytes"
	"testing"
)

// Ported from the Swift suite's FECGroupBufferTests: single-loss recovery,
// parity-before-member reordering, multi-loss deferral to NACK (parity aging
// out), the at-most-once recovery guard for late originals, and the bounded
// media ring. Deterministic — injected nowNs, no I/O.

const fecMs uint64 = 1_000_000

// fecMakeGroup packetizes one H.264 access unit (several packets, contiguous
// seqs) with the same NAL shapes as the Swift helper.
func fecMakeGroup(startSeq uint16, ts uint32) [][]byte {
	nal := func(header byte, n, mul int) []byte {
		out := make([]byte, 0, n+1)
		out = append(out, header)
		for i := 0; i < n; i++ {
			out = append(out, byte((i*mul)&0xFF))
		}
		return out
	}
	nals := [][]byte{
		nal(0x65, 600, 1),
		nal(0x41, 2400, 3),
		nal(0x41, 200, 9),
	}
	return PacketizeH264(nals, ts, 0x1234, startSeq)
}

func fecSeqOf(t *testing.T, packet []byte) uint16 {
	t.Helper()
	header, _, ok := DecodeRTPHeader(packet)
	if !ok {
		t.Fatal("packet does not decode as RTP")
	}
	return header.Sequence
}

func fecParityFor(t *testing.T, group [][]byte) (base uint16, count int, body []byte) {
	t.Helper()
	return fecSeqOf(t, group[0]), len(group), ParityBody(group)
}

func TestFECSingleLossRecoveredOnParityArrival(t *testing.T) {
	group := fecMakeGroup(200, 900)
	lostIndex := 1
	buffer := NewFECGroupBuffer(FECGroupBufferConfig{})
	for i, packet := range group {
		if i == lostIndex {
			continue
		}
		if r := buffer.NoteMedia(fecSeqOf(t, packet), packet, uint64(i)*fecMs); r != nil {
			t.Fatalf("unexpected recovery on media arrival %d", i)
		}
	}
	base, count, body := fecParityFor(t, group)
	recovery := buffer.NoteParity(base, count, body, 10*fecMs)
	if recovery == nil {
		t.Fatal("expected a recovery on parity arrival")
	}
	if recovery.Seq != fecSeqOf(t, group[lostIndex]) {
		t.Fatalf("recovered seq = %d, want %d", recovery.Seq, fecSeqOf(t, group[lostIndex]))
	}
	if !bytes.Equal(recovery.Packet, group[lostIndex]) {
		t.Fatal("recovered packet differs from the lost original")
	}
}

func TestFECParityBeforeReorderedMemberRecovers(t *testing.T) {
	// Parity outruns a reordered member: it arrives with two members still
	// unseen (unsolvable, buffered); the reordered member's arrival makes
	// the group one-missing and solves it.
	group := fecMakeGroup(200, 900)
	buffer := NewFECGroupBuffer(FECGroupBufferConfig{})
	for i, packet := range group {
		if i < 2 {
			continue
		}
		if r := buffer.NoteMedia(fecSeqOf(t, packet), packet, uint64(i)*fecMs); r != nil {
			t.Fatalf("unexpected recovery on media arrival %d", i)
		}
	}
	base, count, body := fecParityFor(t, group)
	if r := buffer.NoteParity(base, count, body, 6*fecMs); r != nil {
		t.Fatal("two missing members — not solvable yet")
	}
	// The reordered member (index 1) lands; index 0 is the true loss.
	recovery := buffer.NoteMedia(fecSeqOf(t, group[1]), group[1], 8*fecMs)
	if recovery == nil {
		t.Fatal("expected the reordered member's arrival to solve the group")
	}
	if recovery.Seq != fecSeqOf(t, group[0]) {
		t.Fatalf("recovered seq = %d, want %d", recovery.Seq, fecSeqOf(t, group[0]))
	}
	if !bytes.Equal(recovery.Packet, group[0]) {
		t.Fatal("recovered packet differs from the lost original")
	}
}

func TestFECTwoLossesNeverRecoverAndParityAgesOut(t *testing.T) {
	group := fecMakeGroup(200, 900)
	buffer := NewFECGroupBuffer(FECGroupBufferConfig{})
	for i, packet := range group {
		if i < 2 {
			continue
		}
		if r := buffer.NoteMedia(fecSeqOf(t, packet), packet, uint64(i)*fecMs); r != nil {
			t.Fatalf("unexpected recovery on media arrival %d", i)
		}
	}
	base, count, body := fecParityFor(t, group)
	if r := buffer.NoteParity(base, count, body, 6*fecMs); r != nil {
		t.Fatal("two missing members must not solve")
	}
	// Past the linger window the parity is purged: even a member arrival
	// that would have made the group solvable recovers nothing — NACK owns
	// multi-loss groups.
	afterLinger := 6*fecMs + buffer.cfg.ParityLingerNs + fecMs
	if r := buffer.NoteMedia(fecSeqOf(t, group[1]), group[1], afterLinger); r != nil {
		t.Fatal("aged-out parity must not recover")
	}
}

func TestFECParityForFullyReceivedGroupIsDropped(t *testing.T) {
	group := fecMakeGroup(200, 900)
	buffer := NewFECGroupBuffer(FECGroupBufferConfig{})
	for i, packet := range group {
		if r := buffer.NoteMedia(fecSeqOf(t, packet), packet, uint64(i)*fecMs); r != nil {
			t.Fatalf("unexpected recovery on media arrival %d", i)
		}
	}
	base, count, body := fecParityFor(t, group)
	if r := buffer.NoteParity(base, count, body, 9*fecMs); r != nil {
		t.Fatal("a parity for a fully received group has nothing to add")
	}
}

func TestFECLateOriginalAfterRecoveryIsNotReEmitted(t *testing.T) {
	group := fecMakeGroup(200, 900)
	buffer := NewFECGroupBuffer(FECGroupBufferConfig{})
	for i, packet := range group {
		if i == 0 {
			continue
		}
		if r := buffer.NoteMedia(fecSeqOf(t, packet), packet, uint64(i)*fecMs); r != nil {
			t.Fatalf("unexpected recovery on media arrival %d", i)
		}
	}
	base, count, body := fecParityFor(t, group)
	recovery := buffer.NoteParity(base, count, body, 8*fecMs)
	if recovery == nil || recovery.Seq != fecSeqOf(t, group[0]) {
		t.Fatal("expected the parity to recover the missing head packet")
	}
	// The reordered original finally arrives: at-most-once guard — no second
	// emission (the packet itself still flows to the depacketizer via the
	// normal wire path, where the reorder buffer dedups it).
	if r := buffer.NoteMedia(fecSeqOf(t, group[0]), group[0], 9*fecMs); r != nil {
		t.Fatal("late original after recovery must not be re-emitted")
	}
	// A duplicated parity for the same group is equally inert.
	if r := buffer.NoteParity(base, count, body, 10*fecMs); r != nil {
		t.Fatal("duplicate parity for a recovered group must be inert")
	}
}

func TestFECMediaRingEvictsOldestUnderMemoryBound(t *testing.T) {
	// A tiny ring: old group members are evicted as fresh packets pour in,
	// so its parity finds ≥ 2 missing and cannot mis-solve.
	oldGroup := fecMakeGroup(0, 900)
	buffer := NewFECGroupBuffer(FECGroupBufferConfig{MaxHeldBytes: 8 * 1024, MaxHeldPackets: 8})
	var now uint64
	for _, packet := range oldGroup {
		now += fecMs
		buffer.NoteMedia(fecSeqOf(t, packet), packet, now)
	}
	// Flood with a later batch to push the old group out.
	flood := fecMakeGroup(1000, 1800)
	for i := 0; i < 4; i++ {
		for _, packet := range flood {
			now += fecMs
			buffer.NoteMedia(fecSeqOf(t, packet), packet, now)
		}
	}
	base, count, body := fecParityFor(t, oldGroup)
	if r := buffer.NoteParity(base, count, body, now+fecMs); r != nil {
		t.Fatal("evicted members must make the old group unsolvable, not mis-solved")
	}
}

func TestFECNoteMediaDoesNotRetainCallersSlice(t *testing.T) {
	group := fecMakeGroup(300, 900)
	buffer := NewFECGroupBuffer(FECGroupBufferConfig{})
	scratch := make([]byte, 0, 4096)
	for i, packet := range group {
		if i == 1 {
			continue
		}
		scratch = append(scratch[:0], packet...) // one reused read buffer
		buffer.NoteMedia(fecSeqOf(t, packet), scratch, uint64(i)*fecMs)
	}
	for i := range scratch {
		scratch[i] = 0xEE // whatever landed in it last is overwritten
	}
	base, count, body := fecParityFor(t, group)
	recovery := buffer.NoteParity(base, count, body, 10*fecMs)
	if recovery == nil || !bytes.Equal(recovery.Packet, group[1]) {
		t.Fatal("held media aliased the caller's reused buffer — recovery corrupted")
	}
}

func TestFECNoteParityDoesNotRetainCallersBody(t *testing.T) {
	group := fecMakeGroup(400, 900)
	buffer := NewFECGroupBuffer(FECGroupBufferConfig{})
	for i, packet := range group {
		if i < 2 {
			continue
		}
		buffer.NoteMedia(fecSeqOf(t, packet), packet, uint64(i)*fecMs)
	}
	base, count, body := fecParityFor(t, group)
	scratch := append([]byte(nil), body...)
	if buffer.NoteParity(base, count, scratch, 6*fecMs) != nil {
		t.Fatal("two missing members must not solve")
	}
	for i := range scratch {
		scratch[i] = 0xEE // the caller reuses its datagram buffer
	}
	// The reordered member arrives; the buffered parity must solve from its
	// own copy of the body, not the caller's overwritten one.
	recovery := buffer.NoteMedia(fecSeqOf(t, group[1]), group[1], 8*fecMs)
	if recovery == nil || !bytes.Equal(recovery.Packet, group[0]) {
		t.Fatal("a buffered parity aliased the caller's body buffer")
	}
}
