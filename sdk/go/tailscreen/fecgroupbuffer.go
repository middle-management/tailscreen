package tailscreen

// FECRecovery is one recovered packet, ready to be fed through the same
// ingest path as a received one (TS-FEC-011).
type FECRecovery struct {
	Seq    uint16
	Packet []byte
}

// FECGroupBufferConfig carries the buffer's bounds; zero values select the
// defaults.
type FECGroupBufferConfig struct {
	// MaxHeldBytes caps retained media bytes — about four keyframe-sized
	// groups.
	MaxHeldBytes int
	// MaxHeldPackets is the second bound alongside bytes.
	MaxHeldPackets int
	// ParityLingerNs is how long an unsolvable parity waits for reordered
	// members before multi-loss groups are left to NACK (TS-FEC-008).
	ParityLingerNs uint64
	// MaxPendingParities caps buffered parities.
	MaxPendingParities int
	// MaxRecoveredGuard caps the at-most-once-recovery guard set.
	MaxRecoveredGuard int
}

func (c FECGroupBufferConfig) withDefaults() FECGroupBufferConfig {
	if c.MaxHeldBytes == 0 {
		c.MaxHeldBytes = 256 * 1024
	}
	if c.MaxHeldPackets == 0 {
		c.MaxHeldPackets = 512
	}
	if c.ParityLingerNs == 0 {
		c.ParityLingerNs = 25_000_000
	}
	if c.MaxPendingParities == 0 {
		c.MaxPendingParities = 16
	}
	if c.MaxRecoveredGuard == 0 {
		c.MaxRecoveredGuard = 256
	}
	return c
}

type pendingParity struct {
	baseSeq     uint16
	count       int
	body        []byte
	firstSeenNs uint64
}

// FECGroupBuffer is the receiver-side FEC state: a bounded ring of recently
// received video packets plus briefly buffered parity datagrams, solved via
// Recover the moment a group has exactly one member missing (TS-FEC-008).
// It sits in front of the depacketizer.
//
// Pure and deterministic — the caller injects nowNs — and not safe for
// concurrent use; the receive path is the only mutator.
type FECGroupBuffer struct {
	cfg FECGroupBufferConfig

	held      map[uint16][]byte
	heldOrder []uint16
	heldBytes int
	pending   []pendingParity
	// recovered guards at-most-once recovery per seq: a late original after a
	// recovery must not be double-fed by us (it still flows to the
	// depacketizer, whose reorder buffer drops it as an ordinary duplicate).
	recovered    []uint16
	recoveredSet map[uint16]bool
}

// NewFECGroupBuffer constructs a buffer; zero-value config fields select the
// defaults.
func NewFECGroupBuffer(cfg FECGroupBufferConfig) *FECGroupBuffer {
	return &FECGroupBuffer{
		cfg:          cfg.withDefaults(),
		held:         make(map[uint16][]byte),
		recoveredSet: make(map[uint16]bool),
	}
}

// NoteMedia retains one received video packet and re-checks any buffered
// parity whose group it may have just made solvable — parity can outrun a
// reordered member. Returns a recovery if one solved.
func (b *FECGroupBuffer) NoteMedia(seq uint16, packet []byte, nowNs uint64) *FECRecovery {
	if _, ok := b.held[seq]; !ok {
		b.held[seq] = packet
		b.heldOrder = append(b.heldOrder, seq)
		b.heldBytes += len(packet)
		b.evictHeldIfNeeded()
	}
	return b.solvePending(nowNs)
}

// NoteParity ingests one parity datagram: solves immediately when exactly one
// group member is missing, drops it when none are, and buffers it for one
// reorder tolerance when two or more are — multi-loss groups belong to NACK.
func (b *FECGroupBuffer) NoteParity(baseSeq uint16, count int, body []byte, nowNs uint64) *FECRecovery {
	b.purgeAgedParities(nowNs)
	parity := pendingParity{baseSeq: baseSeq, count: count, body: body, firstSeenNs: nowNs}
	if recovery := b.trySolve(parity); recovery != nil {
		return recovery
	}
	if len(b.missingSeqs(baseSeq, count)) == 0 {
		return nil // fully received — the parity has nothing to add
	}
	b.pending = append(b.pending, parity)
	if len(b.pending) > b.cfg.MaxPendingParities {
		b.pending = b.pending[len(b.pending)-b.cfg.MaxPendingParities:]
	}
	return nil
}

// Reset clears all state for a fresh session.
func (b *FECGroupBuffer) Reset() {
	b.held = make(map[uint16][]byte)
	b.heldOrder = nil
	b.heldBytes = 0
	b.pending = nil
	b.recovered = nil
	b.recoveredSet = make(map[uint16]bool)
}

func (b *FECGroupBuffer) missingSeqs(baseSeq uint16, count int) []uint16 {
	var missing []uint16
	seq := baseSeq
	for i := 0; i < count; i++ {
		if _, ok := b.held[seq]; !ok {
			missing = append(missing, seq)
		}
		seq++
	}
	return missing
}

// trySolve attempts one parity's group: a recovery comes back when exactly
// one member is missing, that member was not already recovered, and the XOR
// solve is internally consistent (TS-FEC-009, TS-FEC-010).
func (b *FECGroupBuffer) trySolve(parity pendingParity) *FECRecovery {
	missing := b.missingSeqs(parity.baseSeq, parity.count)
	if len(missing) != 1 {
		return nil
	}
	missingSeq := missing[0]
	if b.recoveredSet[missingSeq] {
		return nil
	}

	members := make([][]byte, 0, parity.count-1)
	var ssrc uint32
	seq := parity.baseSeq
	for i := 0; i < parity.count; i++ {
		if member, ok := b.held[seq]; ok {
			members = append(members, member)
			if ssrc == 0 {
				if header, _, ok := DecodeRTPHeader(member); ok {
					ssrc = header.SSRC
				}
			}
		}
		seq++
	}

	packet := Recover(missingSeq, ssrc, members, parity.body)
	if packet == nil {
		return nil
	}

	b.markRecovered(missingSeq)
	// The recovered packet joins the held set like a received one, so an
	// overlapping parity sees a complete group and drops.
	if _, ok := b.held[missingSeq]; !ok {
		b.held[missingSeq] = packet
		b.heldOrder = append(b.heldOrder, missingSeq)
		b.heldBytes += len(packet)
		b.evictHeldIfNeeded()
	}
	return &FECRecovery{Seq: missingSeq, Packet: packet}
}

// solvePending re-runs buffered parities after a media arrival: solve the
// first group that just became one-missing, drop every fully received
// parity, and keep the rest — one scan over a rebuilt slice, so removing a
// satisfied parity never skips or delays the others. At most one recovery
// per call: a media packet belongs to exactly one group per batch, so one
// arrival can complete at most one group.
func (b *FECGroupBuffer) solvePending(nowNs uint64) *FECRecovery {
	b.purgeAgedParities(nowNs)
	if len(b.pending) == 0 {
		return nil
	}
	var recovery *FECRecovery
	remaining := b.pending[:0]
	for _, parity := range b.pending {
		if recovery == nil {
			if solved := b.trySolve(parity); solved != nil {
				recovery = solved // consumed — not retained
				continue
			}
		}
		if len(b.missingSeqs(parity.baseSeq, parity.count)) == 0 {
			continue // fully received — nothing left to add
		}
		remaining = append(remaining, parity)
	}
	b.pending = remaining
	return recovery
}

func (b *FECGroupBuffer) purgeAgedParities(nowNs uint64) {
	kept := b.pending[:0]
	for _, parity := range b.pending {
		if nowNs-parity.firstSeenNs <= b.cfg.ParityLingerNs {
			kept = append(kept, parity)
		}
	}
	b.pending = kept
}

func (b *FECGroupBuffer) markRecovered(seq uint16) {
	b.recovered = append(b.recovered, seq)
	b.recoveredSet[seq] = true
	if len(b.recovered) > b.cfg.MaxRecoveredGuard {
		evicted := b.recovered[0]
		b.recovered = b.recovered[1:]
		delete(b.recoveredSet, evicted)
	}
}

func (b *FECGroupBuffer) evictHeldIfNeeded() {
	for (b.heldBytes > b.cfg.MaxHeldBytes || len(b.heldOrder) > b.cfg.MaxHeldPackets) && len(b.heldOrder) > 0 {
		seq := b.heldOrder[0]
		b.heldOrder = b.heldOrder[1:]
		if packet, ok := b.held[seq]; ok {
			delete(b.held, seq)
			b.heldBytes -= len(packet)
		}
	}
}
