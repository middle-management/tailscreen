package tailscreen

import (
	"bytes"
	"encoding/binary"
	"testing"
)

// avccNALs splits an AVCC access unit back into its NAL units, so a
// round-trip can be checked against what went in.
func avccNALs(t *testing.T, avcc []byte) [][]byte {
	t.Helper()
	var out [][]byte
	for offset := 0; offset < len(avcc); {
		if offset+4 > len(avcc) {
			t.Fatalf("truncated length prefix at offset %d of %d", offset, len(avcc))
		}
		length := int(binary.BigEndian.Uint32(avcc[offset : offset+4]))
		offset += 4
		if offset+length > len(avcc) {
			t.Fatalf("NAL of %d bytes runs past the %d-byte access unit", length, len(avcc))
		}
		out = append(out, avcc[offset:offset+length])
		offset += length
	}
	return out
}

func assertNALsMatch(t *testing.T, got [][]byte, want [][]byte) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("reassembled %d NAL units, want %d", len(got), len(want))
	}
	for i := range want {
		if !bytes.Equal(got[i], want[i]) {
			t.Fatalf("NAL %d came back changed\n  want %x\n  got  %x", i, want[i], got[i])
		}
	}
}

func TestDepacketizerH264RoundTripsWholeAccessUnit(t *testing.T) {
	// Parameter sets, then an IDR — the shape of every keyframe, since the
	// parameter sets ride in band on each one (TS-VID-020).
	nals := [][]byte{
		append([]byte{0x67}, bytes.Repeat([]byte{0xAA}, 11)...), // SPS
		append([]byte{0x68}, bytes.Repeat([]byte{0xBB}, 3)...),  // PPS
		append([]byte{0x65}, bytes.Repeat([]byte{0xCC}, 40)...), // IDR
	}
	packets := PacketizeH264(nals, 9000, 42, 100)

	depacketizer := NewH264Depacketizer(16, 0)
	var au *VideoAccessUnit
	for _, packet := range packets {
		if got := depacketizer.Ingest(packet, 0); got != nil {
			au = got
		}
	}
	if au == nil {
		t.Fatal("no access unit completed")
	}
	assertNALsMatch(t, avccNALs(t, au.AVCC), nals)
	if !au.ContainsIDR {
		t.Error("an access unit carrying NAL type 5 must be flagged as an IDR")
	}
	if au.LostBeforeThisAU {
		t.Error("a complete access unit must not report loss")
	}
	if au.Timestamp != 9000 || au.Codec != "h264" {
		t.Errorf("timestamp %d codec %q, want 9000 h264", au.Timestamp, au.Codec)
	}
}

func TestDepacketizerH264ReassemblesFragmentedNAL(t *testing.T) {
	// One NAL well past the 1100-byte payload limit, so it must arrive as
	// FU-A fragments and be rebuilt byte for byte (TS-VID-032).
	big := make([]byte, 2500)
	big[0] = 0x65
	for i := 1; i < len(big); i++ {
		big[i] = byte(i * 7)
	}
	packets := PacketizeH264([][]byte{big}, 50, 1, 0)
	if len(packets) < 3 {
		t.Fatalf("expected the NAL to fragment, got %d packets", len(packets))
	}

	depacketizer := NewH264Depacketizer(16, 0)
	var au *VideoAccessUnit
	for _, packet := range packets {
		if got := depacketizer.Ingest(packet, 0); got != nil {
			au = got
		}
	}
	if au == nil {
		t.Fatal("no access unit completed")
	}
	assertNALsMatch(t, avccNALs(t, au.AVCC), [][]byte{big})
}

func TestDepacketizerHEVCRoundTripsAndDetectsIRAP(t *testing.T) {
	nals := [][]byte{
		append([]byte{0x40, 0x01}, bytes.Repeat([]byte{0x11}, 10)...), // VPS, type 32
		append([]byte{0x26, 0x01}, bytes.Repeat([]byte{0x22}, 30)...), // IDR_W_RADL, type 19
	}
	packets := PacketizeHEVC(nals, 3000, 7, 500)

	depacketizer := NewH265Depacketizer(16, 0)
	var au *VideoAccessUnit
	for _, packet := range packets {
		if got := depacketizer.Ingest(packet, 0); got != nil {
			au = got
		}
	}
	if au == nil {
		t.Fatal("no access unit completed")
	}
	assertNALsMatch(t, avccNALs(t, au.AVCC), nals)
	if !au.ContainsIDR {
		t.Error("NAL type 19 is in the IRAP range and must set ContainsIDR")
	}
	if au.Codec != "hevc" {
		t.Errorf("codec %q, want hevc", au.Codec)
	}
}

func TestDepacketizerHEVCReassemblesFragmentedNAL(t *testing.T) {
	big := make([]byte, 2600)
	big[0], big[1] = 0x26, 0x01
	for i := 2; i < len(big); i++ {
		big[i] = byte(i*13 + 5)
	}
	packets := PacketizeHEVC([][]byte{big}, 60, 2, 0)
	if len(packets) < 3 {
		t.Fatalf("expected the NAL to fragment, got %d packets", len(packets))
	}

	depacketizer := NewH265Depacketizer(16, 0)
	var au *VideoAccessUnit
	for _, packet := range packets {
		if got := depacketizer.Ingest(packet, 0); got != nil {
			au = got
		}
	}
	if au == nil {
		t.Fatal("no access unit completed")
	}
	// The FU rebuild has to restore F, LayerId and TID exactly, or the NAL
	// header comes back subtly wrong and the decoder rejects the frame.
	assertNALsMatch(t, avccNALs(t, au.AVCC), [][]byte{big})
}

func TestDepacketizerReassemblesDeepKeyframeWithLateRetransmit(t *testing.T) {
	// Ported from the Swift suite: a keyframe-sized access unit loses an early
	// packet whose retransmit arrives ~160 ms later. In time-held mode the
	// frame must come back whole with no loss flag — this is the exact path
	// that used to tear a keyframe and wedge the viewer.
	const t0 uint64 = 1_000_000_000
	nals := make([][]byte, 100)
	for i := range nals {
		nals[i] = []byte{0x41, byte(i)}
	}
	packets := PacketizeH264(nals, 50, 1, 1000)
	if len(packets) != 100 {
		t.Fatalf("expected 100 packets, got %d", len(packets))
	}

	depacketizer := NewH264Depacketizer(512, 300_000_000)
	for i, packet := range packets {
		if i == 1 {
			continue // seq 1001 is lost for now
		}
		if au := depacketizer.Ingest(packet, t0+uint64(i)*300_000); au != nil {
			t.Fatalf("an access unit completed at packet %d while the gap was open", i)
		}
	}

	// The retransmit lands inside the hold.
	au := depacketizer.Ingest(packets[1], t0+160_000_000)
	if au == nil {
		if ready := depacketizer.DrainReady(); len(ready) == 1 {
			au = &ready[0]
		}
	}
	if au == nil {
		t.Fatal("the access unit never reassembled after the retransmit")
	}
	assertNALsMatch(t, avccNALs(t, au.AVCC), nals)
	if au.LostBeforeThisAU {
		t.Error("the frame arrived whole; no loss should be reported")
	}
	if got := depacketizer.TornAUCount(); got != 0 {
		t.Errorf("tore %d access units, want 0", got)
	}
}

func TestDepacketizerCountsTornAccessUnitAndLatchesLoss(t *testing.T) {
	// A packet that never arrives must discard its access unit — a decoder
	// must never be handed a torn frame — and the loss flag must survive onto
	// the next clean one so the viewer still asks for a keyframe.
	nals := make([][]byte, 6)
	for i := range nals {
		nals[i] = append([]byte{0x41}, bytes.Repeat([]byte{byte(i)}, 20)...)
	}
	first := PacketizeH264(nals, 100, 1, 0)
	second := PacketizeH264(nals, 200, 1, uint16(len(first)))

	depacketizer := NewH264Depacketizer(4, 0)
	// Completed units come back from Ingest one at a time, so collect those
	// as well as whatever is still queued at the end.
	var ready []VideoAccessUnit
	for i, packet := range first {
		if i == 2 {
			continue // genuinely lost, never retransmitted
		}
		if au := depacketizer.Ingest(packet, 0); au != nil {
			ready = append(ready, *au)
		}
	}
	for _, packet := range second {
		if au := depacketizer.Ingest(packet, 0); au != nil {
			ready = append(ready, *au)
		}
	}
	ready = append(ready, depacketizer.DrainReady()...)
	if depacketizer.TornAUCount() == 0 {
		t.Fatal("the access unit missing a packet must be counted as torn")
	}
	var clean *VideoAccessUnit
	for i := range ready {
		if ready[i].Timestamp == 200 {
			clean = &ready[i]
		}
	}
	if clean == nil {
		t.Fatal("the following access unit should still have completed")
	}
	if !clean.LostBeforeThisAU {
		t.Error("the loss flag must latch onto the next clean access unit")
	}
}

func TestDepacketizerIgnoresForeignPayloadTypeAndResetsOnNewSSRC(t *testing.T) {
	h264 := PacketizeH264([][]byte{{0x65, 1, 2, 3}}, 1, 1, 0)
	hevc := PacketizeHEVC([][]byte{{0x26, 0x01, 4, 5}}, 1, 1, 0)

	depacketizer := NewH264Depacketizer(16, 0)
	if au := depacketizer.Ingest(hevc[0], 0); au != nil {
		t.Fatal("an H.264 depacketizer must discard a payload type it does not own")
	}
	if au := depacketizer.Ingest(h264[0], 0); au == nil {
		t.Fatal("the H.264 packet should have completed an access unit")
	}

	// A restarted sender means a new SSRC; state must be discarded rather
	// than reassembled across the discontinuity.
	restarted := PacketizeH264([][]byte{{0x65, 9, 9, 9}}, 77, 999, 40000)
	if au := depacketizer.Ingest(restarted[0], 0); au == nil {
		t.Fatal("the first packet of a new SSRC should complete its own access unit")
	}
}
