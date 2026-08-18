import CTailscreen
import Foundation

// Swift wrappers over libtailscreen.a's handle-based stateful pipeline — the
// public Go SDK built as a C archive (`make libtailscreen`). Each class owns
// one handle and frees it on deinit; the differential suites drive these and
// the shipping Swift types with identical input and assert identical output.
//
// The cgo-generated header declares byte parameters as non-const `uint8_t *`,
// so every call copies the bytes into a mutable buffer first.

/// Calls `body` with a mutable C view of `data`.
func withCBytes<R>(_ data: Data, _ body: (UnsafeMutablePointer<UInt8>?, Int32) -> R) -> R {
    if data.isEmpty {
        return body(nil, 0)
    }
    var bytes = [UInt8](data)
    return bytes.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress, Int32(buffer.count))
    }
}

/// Takes ownership of a `tailscreen_buf`: copies it into a `Data` and frees
/// the C allocation. A NULL buffer (the ABI's "rejected / nothing") is nil.
func takeBuf(_ buf: tailscreen_buf) -> Data? {
    guard let pointer = buf.data else { return nil }
    let out = Data(bytes: pointer, count: Int(buf.len))
    tailscreen_free(pointer)
    return out
}

/// A NACK-scheduler decision in a representation both implementations map
/// onto, so the suites can compare action streams directly.
enum DifferentialNACKAction: Equatable {
    case nack([UInt16])
    case pli
}

final class GoReorderBuffer {
    struct Release: Equatable {
        let packet: Data
        let lostBefore: Bool
    }

    private let handle: Int64

    init(maxDepth: Int, gapHoldNs: UInt64) {
        handle = tailscreen_reorder_new(Int32(maxDepth), gapHoldNs)
    }

    deinit { tailscreen_reorder_free(handle) }

    func push(seq: UInt16, packet: Data, nowNs: UInt64) -> [Release] {
        _ = withCBytes(packet) { pointer, length in
            tailscreen_reorder_push(handle, seq, pointer, length, nowNs)
        }
        var out: [Release] = []
        var release = tailscreen_release()
        while tailscreen_reorder_next_release(handle, &release) == 1 {
            var data = Data()
            if let pointer = release.packet {
                data = Data(bytes: pointer, count: Int(release.len))
                tailscreen_free(pointer)
            }
            out.append(Release(packet: data, lostBefore: release.lost_before == 1))
        }
        return out
    }

    var skippedGapCount: Int { Int(tailscreen_reorder_skipped_gaps(handle)) }
}

final class GoDepacketizer {
    struct AccessUnit: Equatable {
        let avcc: Data
        let containsIDR: Bool
        let timestamp: UInt32
        let lostBefore: Bool
        let isHEVC: Bool
    }

    private let handle: Int64

    init(hevc: Bool, reorderDepth: Int, gapHoldNs: UInt64) {
        handle = tailscreen_depacketizer_new(hevc ? 1 : 0, Int32(reorderDepth), gapHoldNs)
    }

    deinit { tailscreen_depacketizer_free(handle) }

    func ingest(_ packet: Data, nowNs: UInt64) -> [AccessUnit] {
        _ = withCBytes(packet) { pointer, length in
            tailscreen_depacketizer_ingest(handle, pointer, length, nowNs)
        }
        var out: [AccessUnit] = []
        var au = tailscreen_au()
        while tailscreen_depacketizer_next_au(handle, &au) == 1 {
            var avcc = Data()
            if let pointer = au.avcc {
                avcc = Data(bytes: pointer, count: Int(au.len))
                tailscreen_free(pointer)
            }
            out.append(
                AccessUnit(
                    avcc: avcc,
                    containsIDR: au.contains_idr == 1,
                    timestamp: au.timestamp,
                    lostBefore: au.lost_before == 1,
                    isHEVC: au.hevc == 1))
        }
        return out
    }

    var tornAUCount: Int { Int(tailscreen_depacketizer_torn_au_count(handle)) }
    var skippedGapCount: Int { Int(tailscreen_depacketizer_skipped_gap_count(handle)) }
}

final class GoNACKScheduler {
    private let handle: Int64

    init(
        reorderToleranceNs: UInt64 = 0, reorderPacketTolerance: Int = 0,
        maxAttempts: Int = 0, reNackFloorNs: UInt64 = 0, ringWindowNs: UInt64 = 0,
        maxNacksPerSecond: Int = 0, maxGaps: Int = 0, initialRTTNs: UInt64 = 0
    ) {
        handle = tailscreen_nack_new(
            reorderToleranceNs, Int32(reorderPacketTolerance),
            Int32(maxAttempts), reNackFloorNs, ringWindowNs,
            Int32(maxNacksPerSecond), Int32(maxGaps), initialRTTNs)
    }

    deinit { tailscreen_nack_free(handle) }

    private func drainActions() -> [DifferentialNACKAction] {
        var out: [DifferentialNACKAction] = []
        var action = tailscreen_nack_action()
        while tailscreen_nack_next_action(handle, &action) == 1 {
            if action.pli == 1 {
                out.append(.pli)
            } else {
                var seqs: [UInt16] = []
                if let pointer = action.seqs {
                    seqs = Array(UnsafeBufferPointer(start: pointer, count: Int(action.count)))
                    tailscreen_free(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: UInt8.self))
                }
                out.append(.nack(seqs))
            }
        }
        return out
    }

    func observe(seq: UInt16, nowNs: UInt64) -> [DifferentialNACKAction] {
        _ = tailscreen_nack_observe(handle, seq, nowNs)
        return drainActions()
    }

    func tick(nowNs: UInt64) -> [DifferentialNACKAction] {
        _ = tailscreen_nack_tick(handle, nowNs)
        return drainActions()
    }

    func cancelGap(seq: UInt16) { tailscreen_nack_cancel_gap(handle, seq) }
    func noteRecovered(seq: UInt16, nowNs: UInt64) { tailscreen_nack_note_recovered(handle, seq, nowNs) }
    func setReorderTolerances(toleranceNs: UInt64, packetTolerance: Int) {
        tailscreen_nack_set_reorder_tolerances(handle, toleranceNs, Int32(packetTolerance))
    }
    func drainNackRecovered() -> Int { Int(tailscreen_nack_drain_recovered(handle)) }
    var rttEstimateNs: UInt64 { tailscreen_nack_rtt_estimate_ns(handle) }
    var hasOpenGaps: Bool { tailscreen_nack_has_open_gaps(handle) == 1 }
}

func goFCICappedSeqs(_ seqs: [UInt16], maxEntries: Int) -> [UInt16] {
    var input = seqs
    var out = [UInt16](repeating: 0, count: max(seqs.count, 1))
    let written = input.withUnsafeMutableBufferPointer { inBuffer in
        out.withUnsafeMutableBufferPointer { outBuffer in
            tailscreen_fci_capped_seqs(
                inBuffer.baseAddress, Int32(seqs.count), Int32(maxEntries),
                outBuffer.baseAddress, Int32(outBuffer.count))
        }
    }
    return Array(out.prefix(Int(written)))
}

func goPackFCI(_ seqs: [UInt16]) -> [(pid: UInt16, blp: UInt16)] {
    var input = seqs
    let capacity = max(seqs.count, 1)
    var pids = [UInt16](repeating: 0, count: capacity)
    var blps = [UInt16](repeating: 0, count: capacity)
    let written = input.withUnsafeMutableBufferPointer { inBuffer in
        pids.withUnsafeMutableBufferPointer { pidBuffer in
            blps.withUnsafeMutableBufferPointer { blpBuffer in
                tailscreen_pack_fci(
                    inBuffer.baseAddress, Int32(seqs.count),
                    pidBuffer.baseAddress, blpBuffer.baseAddress, Int32(capacity))
            }
        }
    }
    return (0..<Int(written)).map { (pid: pids[$0], blp: blps[$0]) }
}

final class GoFECGroupBuffer {
    struct Recovery: Equatable {
        let seq: UInt16
        let packet: Data
    }

    private let handle: Int64

    init() {
        handle = tailscreen_fec_buffer_new(0, 0, 0, 0, 0)  // all defaults
    }

    deinit { tailscreen_fec_buffer_free(handle) }

    func noteMedia(seq: UInt16, packet: Data, nowNs: UInt64) -> Recovery? {
        var recoveredSeq: UInt16 = 0
        let buf = withCBytes(packet) { pointer, length in
            tailscreen_fec_note_media(handle, seq, pointer, length, nowNs, &recoveredSeq)
        }
        guard let data = takeBuf(buf) else { return nil }
        return Recovery(seq: recoveredSeq, packet: data)
    }

    func noteParity(baseSeq: UInt16, count: Int, body: Data, nowNs: UInt64) -> Recovery? {
        var recoveredSeq: UInt16 = 0
        let buf = withCBytes(body) { pointer, length in
            tailscreen_fec_note_parity(handle, baseSeq, Int32(count), pointer, length, nowNs, &recoveredSeq)
        }
        guard let data = takeBuf(buf) else { return nil }
        return Recovery(seq: recoveredSeq, packet: data)
    }
}

final class GoRRAccounting {
    private let handle: Int64

    init() { handle = tailscreen_rr_new() }
    deinit { tailscreen_rr_free(handle) }

    func observe(seq: UInt16) { tailscreen_rr_observe(handle, seq) }
    var hasBaseline: Bool { tailscreen_rr_has_baseline(handle) == 1 }

    func makeReport() -> (fracLostQ8: UInt8, extHighestSeq: UInt32)? {
        var frac: UInt8 = 0
        var ext: UInt32 = 0
        guard tailscreen_rr_make_report(handle, &frac, &ext) == 1 else { return nil }
        return (frac, ext)
    }
}

func goExtendSeq(_ seq: UInt16, near: Int64) -> Int64 {
    tailscreen_extend_seq(seq, near)
}
