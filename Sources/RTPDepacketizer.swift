import Foundation

/// Inverse of ``RTPPacketizer``. Accepts raw UDP datagrams, emits complete
/// AVCC access units ready for ``VideoDecoder`` / the client's display layer.
///
/// Design notes:
/// - **Strict in-order processing.** Any out-of-order or missing packet
///   within an access unit discards the partial frame and reports loss.
///   The plan calls for a 3-packet jitter buffer; real-world reordering on
///   a tailnet is rare enough that the simpler model wins on complexity
///   versus the ~50 ms of worst-case recovery that a keyframe request
///   costs. Revisit if packet captures show in-flight reordering.
/// - **Only Single NAL (type 1-23) and FU-A (type 28)** are supported,
///   matching ``RTPPacketizer``. Unknown types are logged and dropped.
/// - Output NALs are re-wrapped in 4-byte big-endian length prefixes to
///   match VideoToolbox's AVCC input expectation.
final class RTPDepacketizer {
    /// Emits a complete H.264 access unit (AVCC format, ready to hand to
    /// ``VideoDecoder``) plus a keyframe hint (true if any NAL in the unit
    /// is an IDR slice, NAL type 5).
    var onAccessUnit: ((_ accessUnit: Data, _ isKeyframe: Bool) -> Void)?

    /// Fires when a gap or corruption is detected. The caller should use
    /// this as a cue to send a `.keyframeRequest` over the control channel.
    /// The associated value is the number of packets believed to be lost;
    /// use only for logging.
    var onLoss: ((_ missing: Int) -> Void)?

    // Stream state.
    private var expectedSeq: UInt16? = nil
    private var currentTimestamp: UInt32? = nil
    private var currentUnit: Data = Data()      // AVCC-formatted, accumulated
    private var currentHasKeyframe: Bool = false
    private var fuaBuffer: Data? = nil          // reassembled NAL body (excl. header)
    private var fuaNALHeader: UInt8 = 0
    private var frameCorrupt: Bool = false

    func feed(_ datagram: Data) {
        guard datagram.count >= 12 else {
            // RTP header is 12 bytes; too short to parse.
            reportLoss(1)
            dropCurrentUnit()
            return
        }

        let b0 = datagram[datagram.startIndex]
        let version = (b0 >> 6) & 0x03
        guard version == 2 else {
            // Not an RTP packet we understand.
            return
        }
        let csrcCount = Int(b0 & 0x0F)
        let extensionBit = (b0 & 0x10) != 0

        let b1 = datagram[datagram.index(datagram.startIndex, offsetBy: 1)]
        let marker = (b1 & 0x80) != 0
        // PT ignored; we only negotiate one payload type end-to-end.

        let seq = datagram.readBigEndian(UInt16.self,
                                         at: datagram.index(datagram.startIndex, offsetBy: 2))
        let ts = datagram.readBigEndian(UInt32.self,
                                        at: datagram.index(datagram.startIndex, offsetBy: 4))

        var payloadStart = datagram.index(datagram.startIndex, offsetBy: 12 + 4 * csrcCount)
        if extensionBit {
            // RTP header extension: 4-byte profile/length, then `length` 32-bit words.
            guard datagram.distance(from: payloadStart, to: datagram.endIndex) >= 4 else {
                reportLoss(1); dropCurrentUnit(); return
            }
            let extWordsOffset = datagram.index(payloadStart, offsetBy: 2)
            let extWords = Int(datagram.readBigEndian(UInt16.self, at: extWordsOffset))
            payloadStart = datagram.index(payloadStart, offsetBy: 4 + 4 * extWords)
        }
        guard payloadStart < datagram.endIndex else {
            reportLoss(1); dropCurrentUnit(); return
        }

        // Sequence check.
        if let expected = expectedSeq {
            let gap = Int(seq &- expected)
            if gap != 0 {
                // Anything non-zero (including wrap-around misinterpretation) is a gap.
                reportLoss(gap > 0 ? gap : 1)
                frameCorrupt = true
            }
        }
        expectedSeq = seq &+ 1

        // Timestamp change = frame boundary (independent of marker bit, since
        // a lost last-packet still needs handling).
        if let currentTs = currentTimestamp, ts != currentTs {
            // New frame starting, but the previous one never got its marker.
            // Treat the previous as incomplete.
            dropCurrentUnit()
        }
        if currentTimestamp == nil {
            currentTimestamp = ts
        }

        let payload = datagram[payloadStart..<datagram.endIndex]
        guard !payload.isEmpty else { return }

        let nalHeader = payload[payload.startIndex]
        let nalType = nalHeader & 0b0001_1111

        switch nalType {
        case 1...23:
            // Single NAL unit packet. Payload IS the NAL.
            if !frameCorrupt {
                appendNAL(Data(payload))
                if nalType == 5 { currentHasKeyframe = true }
            }

        case 28:
            // FU-A fragmentation.
            guard payload.count >= 2 else {
                frameCorrupt = true
                return
            }
            let fuIndicator = nalHeader
            let fuHeader = payload[payload.index(after: payload.startIndex)]
            let isStart = (fuHeader & 0b1000_0000) != 0
            let isEnd   = (fuHeader & 0b0100_0000) != 0
            let origType = fuHeader & 0b0001_1111
            let reconstructedNALHeader = (fuIndicator & 0b1110_0000) | origType
            let fragBodyStart = payload.index(payload.startIndex, offsetBy: 2)
            let fragBody = payload[fragBodyStart..<payload.endIndex]

            if isStart {
                // Start fresh. Any previous FU-A state is wrong.
                fuaBuffer = Data()
                fuaNALHeader = reconstructedNALHeader
            } else if fuaBuffer == nil {
                // Continuation without a start — we lost the S packet.
                frameCorrupt = true
                return
            }
            fuaBuffer?.append(fragBody)

            if isEnd {
                if !frameCorrupt, var body = fuaBuffer {
                    // Prepend reconstructed NAL header.
                    body.insert(fuaNALHeader, at: body.startIndex)
                    appendNAL(body)
                    if origType == 5 { currentHasKeyframe = true }
                }
                fuaBuffer = nil
            }

        case 24, 25, 26, 27, 29:
            // Aggregation / other FU / MTAP — not supported; drop frame.
            frameCorrupt = true

        default:
            // NAL type 0 (reserved) or unknown. Drop frame.
            frameCorrupt = true
        }

        if marker {
            emitCurrentUnit()
        }
    }

    // MARK: - helpers

    private func appendNAL(_ nal: Data) {
        var lengthPrefix = Data(count: 4)
        let n = UInt32(nal.count)
        lengthPrefix[0] = UInt8((n >> 24) & 0xFF)
        lengthPrefix[1] = UInt8((n >> 16) & 0xFF)
        lengthPrefix[2] = UInt8((n >> 8) & 0xFF)
        lengthPrefix[3] = UInt8(n & 0xFF)
        currentUnit.append(lengthPrefix)
        currentUnit.append(nal)
    }

    private func emitCurrentUnit() {
        defer {
            currentUnit.removeAll(keepingCapacity: true)
            currentTimestamp = nil
            currentHasKeyframe = false
            fuaBuffer = nil
            frameCorrupt = false
        }
        guard !frameCorrupt, !currentUnit.isEmpty else {
            return
        }
        onAccessUnit?(currentUnit, currentHasKeyframe)
    }

    private func dropCurrentUnit() {
        currentUnit.removeAll(keepingCapacity: true)
        currentTimestamp = nil
        currentHasKeyframe = false
        fuaBuffer = nil
        frameCorrupt = false
    }

    private func reportLoss(_ count: Int) {
        onLoss?(max(1, count))
    }

    /// Reset all accumulated state. Use when the control channel tells us a
    /// new session is starting (e.g. fresh SPS/PPS).
    func reset() {
        expectedSeq = nil
        dropCurrentUnit()
    }
}
