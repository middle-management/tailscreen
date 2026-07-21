import Foundation

/// RTP wire format used between the screen-share server and viewers (RFC 3550 +
/// RFC 6184 H.264 payload + RFC 7798 HEVC payload). The same UDP socket also
/// carries small "control" datagrams from the viewer back to the server (HELLO,
/// KEEPALIVE, BYE, PLI). We disambiguate by the first byte: real RTP packets
/// are V=2, so byte 0 is always in the range 0x80-0xBF; control packets use
/// 0x00-0x7F. Codec is signalled by the RTP payload type (96 = H.264, 97 =
/// HEVC) so a viewer can demux without out-of-band negotiation.
///
/// Single byte at offset 0 of every datagram on the wire:
///
///     0x00 (HELLO)      viewer → server: register me, please send IDR
///     0x01 (KEEPALIVE)  viewer → server: I'm still here
///     0x02 (BYE)        viewer → server: drop me from the fan-out set
///     0x03 (PLI)        viewer → server: I lost something, please send IDR
///     0x04 (HELLO_ACK)  server → viewer: 4-byte SSRC payload — assigns the
///                       viewer's audio SSRC. Sent in response to HELLO.
///     0x05 (SERVER_BYE) server → viewer: I'm stopping, drop the session
///     0x06 (HELLO_PEND) server → viewer: your HELLO is parked behind the
///                       sharer's approval gate; sit tight. Resent on every
///                       HELLO retry while still pending.
///     0x07 (CODEC_NO)   viewer → server: I can't decode this codec; please
///                       fall back to H.264. Sent when VideoToolbox can't
///                       build a decompression session (e.g. an HEVC stream
///                       on a Mac without HEVC decode).
///     0x08 (HELLO_DENY) server → viewer: the sharer declined (or has
///                       blocked) this viewer. Sent just before SERVER_BYE
///                       so the viewer can show "the sharer declined your
///                       request" instead of the generic peer-closed
///                       teardown. Old viewers ignore the unknown byte and
///                       still tear down on the SERVER_BYE that follows.
///     0x09 (PROFILE_NO) viewer → server: I can decode this codec but not this
///                       profile/bit-depth; please fall back to 8-bit. Sent
///                       when a Main 10 (10-bit HEVC) stream reaches a viewer
///                       whose hardware only decodes 8-bit HEVC — a lighter
///                       fallback than CODEC_NO (stay on HEVC, just drop to
///                       8-bit) for the 10-bit/HDR path.
///     0x80..0xBF        RTP packet (V=2)
public enum ScreenShareControlMessage: UInt8, CaseIterable {
    case hello = 0x00
    case keepalive = 0x01
    case bye = 0x02
    case pli = 0x03
    case helloAck = 0x04
    /// Sharer→viewer "I'm gone." Lets the viewer tear down immediately on
    /// `Stop Sharing` instead of waiting out the 15 s no-video idle timer.
    case serverBye = 0x05
    /// Sharer→viewer "you're in the approval queue." Sent when the viewer's
    /// HELLO lands while `requireApproval` is on, so the viewer can show a
    /// "waiting for approval" overlay instead of sitting on a black window.
    case helloPending = 0x06
    /// Viewer→sharer "I can't decode this codec." Sent when the viewer's
    /// VideoToolbox can't build a decompression session for the stream —
    /// typically an HEVC stream reaching a Mac without HEVC hardware decode.
    /// The sharer responds by latching the share to H.264, which every Mac
    /// can decode.
    case codecUnsupported = 0x07
    /// Sharer→viewer "the sharer declined your request." Sent by `denyViewer`
    /// (and the blocked-peer rejection paths) alongside SERVER_BYE so the
    /// viewer can distinguish "declined/blocked" from "sharer stopped".
    case helloDenied = 0x08

    /// Viewer→sharer "I can decode this codec but not its profile/bit-depth."
    /// Sent when a 10-bit HEVC Main 10 stream reaches a viewer whose hardware
    /// only decodes 8-bit HEVC. The sharer responds by latching the share to
    /// 8-bit (staying on HEVC) rather than all the way to H.264 — a lighter
    /// fallback than `codecUnsupported`. Ignored by servers that never emit
    /// 10-bit; unknown bytes are dropped, so it's backward compatible.
    case profileUnsupported = 0x09

    /// Viewer→sharer generic NACK (RFC 4588 generic-NACK FCI semantics).
    /// Requests selective retransmission of missing RTP sequence numbers in
    /// *this viewer's* sequence space:
    ///     `[0x0A][count:1][(pid:2 BE, blp:2 BE) × count]`
    /// where `pid` is the first missing seq and `blp` is a bitmask of the 16
    /// sequence numbers following it. The sharer retransmits byte-identical
    /// RTP from its send-side ring, or falls back to PLI when the gap is too
    /// old / over budget. Capability-negotiated (see `ScreenShareCaps`): a
    /// server that never advertised NACK support drops the unknown byte, so a
    /// new viewer paired with an old server stays on the PLI path.
    case nack = 0x0A

    /// Viewer→sharer RTCP-RR-style receiver report (~1 Hz):
    ///     `[0x0B][fracLostQ8:1][extHighestSeq:4][jitterTicks:4]
    ///      [lastPingTs:8][delaySincePingMs:2]`
    /// Feeds the sharer's receiver-feedback congestion controller with real
    /// loss fraction, cumulative sequence position, RTP jitter, and an RTT
    /// echo (`lastPingTs` + `delaySincePingMs` — the last `ping` this viewer
    /// saw and how long it held it before reporting).
    case receiverReport = 0x0B

    /// Sharer→viewer RTT ping (~1 Hz, piggybacked on the idle sweep):
    ///     `[0x0C][serverUptimeNs:8]`
    /// The viewer echoes `serverUptimeNs` back in its next `receiverReport`
    /// (as `lastPingTs`) so the sharer can compute RTT = now − lastPingTs −
    /// delaySincePingMs. Server→viewer only; ignored if a viewer sends it.
    case ping = 0x0C

    /// Sharer→viewer XOR parity datagram (single-parity FEC, one per group of
    /// ≤ N media packets):
    ///     `[0x0D][baseSeq:2 BE][count:1][xor body:variable]`
    /// `baseSeq` is the group's first sequence number in *that viewer's*
    /// sequence space (per-viewer rewrite, same trick as retransmits); `count`
    /// is the group size k (2…16, contiguous by construction — no mask
    /// needed). The body is the XOR over each covered packet of
    /// `[len:2 BE][byte1][timestamp:4][payload…]`, zero-padded to the longest
    /// member (see `FECCodec`), so the viewer can reconstruct any *one* lost
    /// packet — including the marker packet — with zero additional RTT.
    /// Parity rides the control plane (not an RTP PT) so losing parity opens
    /// no media-seq gap: no NACK, no RR loss, just an uncovered group.
    /// Capability-negotiated (`ScreenShareCaps.fec`); old viewers drop the
    /// unknown byte, old servers never receive it (server→viewer only).
    case fec = 0x0D

    public static func encode(_ kind: ScreenShareControlMessage) -> Data {
        Data([kind.rawValue])
    }

    public static func decode(_ data: Data) -> ScreenShareControlMessage? {
        guard let first = data.first, let kind = ScreenShareControlMessage(rawValue: first) else { return nil }
        return kind
    }

    /// True if the first byte of `data` is a non-RTP control packet rather
    /// than an RTP packet (V=2, MSB pattern 10xx_xxxx).
    public static func looksLikeControl(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        return (first & 0xC0) != 0x80
    }

    /// Encode a HELLO_ACK with a 4-byte big-endian SSRC payload.
    public static func encodeHelloAck(ssrc: UInt32) -> Data {
        var data = Data(capacity: 5)
        data.append(helloAck.rawValue)
        data.appendBE(ssrc)
        return data
    }

    /// Parse a HELLO_ACK datagram. Returns the SSRC, or nil if malformed.
    /// Strict 5-byte form used by legacy viewers — a 6-byte extended ack
    /// (with server caps) is rejected here, which is exactly the
    /// backward-compat mechanism: an old viewer never enters NACK mode.
    public static func decodeHelloAck(_ data: Data) -> UInt32? {
        guard data.count == 5, data[data.startIndex] == helloAck.rawValue else { return nil }
        return data.readBE(UInt32.self, at: data.startIndex + 1)
    }

    // MARK: - Capability handshake (NACK / receiver-report negotiation)

    /// Encode an extended HELLO carrying the viewer's capability bits:
    /// `[0x00][caps:1]`. Old servers read byte 0 only, so the extra byte is
    /// invisible to them; a cap-aware server records the bits and replies with
    /// an extended HELLO_ACK.
    public static func encodeHello(caps: ScreenShareCaps) -> Data {
        Data([hello.rawValue, caps.rawValue])
    }

    /// Read the capability byte off a HELLO. Returns `[]` for a legacy 1-byte
    /// HELLO (no advertised capabilities).
    public static func decodeHelloCaps(_ data: Data) -> ScreenShareCaps {
        guard data.count >= 2, data[data.startIndex] == hello.rawValue else { return [] }
        return ScreenShareCaps(rawValue: data[data.startIndex + 1])
    }

    /// Encode an extended HELLO_ACK: `[0x04][ssrc:4 BE][serverCaps:1]` (6
    /// bytes). Sent only to cap-advertising viewers — a legacy viewer's
    /// strict `decodeHelloAck` would reject the 6-byte form, so the server
    /// keeps sending it the plain 5-byte ack via `encodeHelloAck(ssrc:)`.
    public static func encodeHelloAck(ssrc: UInt32, caps: ScreenShareCaps) -> Data {
        var data = Data(capacity: 6)
        data.append(helloAck.rawValue)
        data.appendBE(ssrc)
        data.append(caps.rawValue)
        return data
    }

    /// Tolerant HELLO_ACK parser used by cap-aware viewers: accepts both the
    /// legacy 5-byte form (caps `[]`) and the 6-byte extended form. Returns
    /// the SSRC plus the server's advertised caps, or nil if malformed.
    public static func decodeHelloAckCaps(_ data: Data) -> (ssrc: UInt32, caps: ScreenShareCaps)? {
        guard data.count >= 5, data[data.startIndex] == helloAck.rawValue else { return nil }
        let ssrc = data.readBE(UInt32.self, at: data.startIndex + 1)
        let caps = data.count >= 6 ? ScreenShareCaps(rawValue: data[data.startIndex + 5]) : []
        return (ssrc, caps)
    }

    // MARK: - NACK / receiver report / ping codecs

    /// Encode a generic NACK. Each entry is `(pid, blp)` in the viewer's own
    /// sequence space; `count` is capped at 16 (69 bytes max on the wire).
    public static func encodeNACK(_ entries: [(pid: UInt16, blp: UInt16)]) -> Data {
        let capped = Array(entries.prefix(16))
        var data = Data(capacity: 2 + capped.count * 4)
        data.append(nack.rawValue)
        data.append(UInt8(capped.count))
        for entry in capped {
            data.appendBE(entry.pid)
            data.appendBE(entry.blp)
        }
        return data
    }

    /// Parse a generic NACK back into its `(pid, blp)` entries. Returns `[]`
    /// on any malformation (short buffer, truncated entry list).
    public static func decodeNACK(_ data: Data) -> [(pid: UInt16, blp: UInt16)] {
        guard data.count >= 2, data[data.startIndex] == nack.rawValue else { return [] }
        let count = Int(data[data.startIndex + 1])
        guard data.count >= 2 + count * 4 else { return [] }
        var out: [(pid: UInt16, blp: UInt16)] = []
        out.reserveCapacity(count)
        var idx = data.startIndex + 2
        for _ in 0..<count {
            let pid = data.readBE(UInt16.self, at: idx)
            let blp = data.readBE(UInt16.self, at: data.index(idx, offsetBy: 2))
            out.append((pid, blp))
            idx = data.index(idx, offsetBy: 4)
        }
        return out
    }

    /// Encode a receiver report. See `receiverReport` for the layout. Pass
    /// `includeRecoveryFields: true` (FEC negotiated) to append the trailing
    /// `[fecRecovered:2 BE][nackRecovered:2 BE]` — the 24-byte extended form.
    /// The default emits the legacy 20-byte layout so pre-FEC servers see
    /// exactly the bytes they already parse (all decoders are length-tolerant:
    /// a 22-byte FEC-era decoder reads `fecRecovered` and ignores the trailing
    /// two, a 20-byte decoder ignores both).
    public static func encodeReceiverReport(_ report: ReceiverReport, includeRecoveryFields: Bool = false) -> Data {
        var data = Data(capacity: includeRecoveryFields ? 24 : 20)
        data.append(receiverReport.rawValue)
        data.append(report.fracLostQ8)
        data.appendBE(report.extHighestSeq)
        data.appendBE(report.jitterTicks)
        data.appendBE(report.lastPingTs)
        data.appendBE(report.delaySincePingMs)
        if includeRecoveryFields {
            data.appendBE(report.fecRecovered)
            data.appendBE(report.nackRecovered)
        }
        return data
    }

    /// Parse a receiver report; nil if malformed (needs at least the 20-byte
    /// legacy layout). The optional trailing `[fecRecovered:2 BE]` (≥22 bytes)
    /// and `[nackRecovered:2 BE]` (≥24 bytes) decode when present and read as 0
    /// otherwise — the same both-forms tolerance as `decodeHelloAckCaps`.
    public static func decodeReceiverReport(_ data: Data) -> ReceiverReport? {
        guard data.count >= 20, data[data.startIndex] == receiverReport.rawValue else { return nil }
        let base = data.startIndex
        let fecRecovered: UInt16 =
            data.count >= 22
            ? data.readBE(UInt16.self, at: data.index(base, offsetBy: 20))
            : 0
        let nackRecovered: UInt16 =
            data.count >= 24
            ? data.readBE(UInt16.self, at: data.index(base, offsetBy: 22))
            : 0
        return ReceiverReport(
            fracLostQ8: data[data.index(base, offsetBy: 1)],
            extHighestSeq: data.readBE(UInt32.self, at: data.index(base, offsetBy: 2)),
            jitterTicks: data.readBE(UInt32.self, at: data.index(base, offsetBy: 6)),
            lastPingTs: data.readBE(UInt64.self, at: data.index(base, offsetBy: 10)),
            delaySincePingMs: data.readBE(UInt16.self, at: data.index(base, offsetBy: 18)),
            fecRecovered: fecRecovered,
            nackRecovered: nackRecovered
        )
    }

    /// Encode a PING carrying the server's monotonic uptime clock.
    public static func encodePing(serverUptimeNs: UInt64) -> Data {
        var data = Data(capacity: 9)
        data.append(ping.rawValue)
        data.appendBE(serverUptimeNs)
        return data
    }

    /// Parse a PING; nil if malformed (needs 9 bytes).
    public static func decodePing(_ data: Data) -> UInt64? {
        guard data.count >= 9, data[data.startIndex] == ping.rawValue else { return nil }
        return data.readBE(UInt64.self, at: data.startIndex + 1)
    }

    // MARK: - FEC codec (see `fec`)

    /// Encode one XOR-parity datagram: `[0x0D][baseSeq:2 BE][count:1][body]`.
    /// `count` must be in `FECCodec.minGroupSize...FECCodec.maxGroupSize`;
    /// the caller (group packing via `FECCodec.groupRanges`) guarantees it.
    public static func encodeFEC(baseSeq: UInt16, count: Int, body: Data) -> Data {
        var data = Data(capacity: 4 + body.count)
        data.append(fec.rawValue)
        data.appendBE(baseSeq)
        data.append(UInt8(truncatingIfNeeded: count))
        data.append(body)
        return data
    }

    /// Parse an FEC datagram. This is untrusted UDP input, so every field is
    /// bounds-checked: nil on a short buffer, an out-of-range group count, a
    /// body too short to carry the XORed `[len:2][byte1][ts:4]` prefix, or a
    /// body larger than any legitimate parity (`FECCodec.maxBodyBytes` — the
    /// prefix plus one full MTU payload region) — truncated/garbage/oversized
    /// datagrams reject cleanly instead of feeding the recovery solve.
    public static func decodeFEC(_ data: Data) -> (baseSeq: UInt16, count: Int, body: Data)? {
        guard data.count >= 4 + FECCodec.minBodyBytes, data[data.startIndex] == fec.rawValue else { return nil }
        guard data.count <= 4 + FECCodec.maxBodyBytes else { return nil }
        let baseSeq = data.readBE(UInt16.self, at: data.startIndex + 1)
        let count = Int(data[data.startIndex + 3])
        guard count >= FECCodec.minGroupSize, count <= FECCodec.maxGroupSize else { return nil }
        let body = Data(data[data.index(data.startIndex, offsetBy: 4)..<data.endIndex])
        return (baseSeq, count, body)
    }
}

/// Capability bits negotiated in the extended HELLO / HELLO_ACK. A viewer
/// advertises what it can do; the server replies with what it supports; each
/// side enables a feature only when both advertised it. Absent (legacy 1-byte
/// HELLO / 5-byte ack) means `[]` — the PLI-only path, unchanged.
public struct ScreenShareCaps: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Viewer detects sequence gaps and requests selective retransmission;
    /// server retransmits from its send-side ring.
    public static let nack = ScreenShareCaps(rawValue: 1 << 0)
    /// Viewer sends periodic receiver reports; server pings for RTT.
    public static let receiverReport = ScreenShareCaps(rawValue: 1 << 1)
    /// Viewer can consume XOR-parity datagrams (`fec` / 0x0D) and reports
    /// FEC-recovered packets in the extended receiver report; server emits
    /// adaptive single-parity FEC to gated viewers. Like `.nack`, each side
    /// enables the feature only when both advertised it — an old peer sees
    /// an unknown OptionSet bit and ignores it.
    public static let fec = ScreenShareCaps(rawValue: 1 << 2)
    /// **Sharer→viewer only** (set in the server's HELLO_ACK caps, never in a
    /// viewer's HELLO): this sharer's build/platform can inject viewer input,
    /// so the viewer should offer its "Request Control" affordance. Absence
    /// means the sharer can't do remote control at all (e.g. a future
    /// non-injection Linux/Windows sharer) — the viewer hides the request so
    /// the user isn't clicking a button that silently does nothing (old
    /// behavior: the `.controlRequest` was skipped as an unknown TCP type
    /// with no feedback). This is *static* capability; the runtime "Allow
    /// control requests" toggle and the Accessibility gate still answer a
    /// live request with an immediate `.controlRevoked` decline.
    public static let remoteControl = ScreenShareCaps(rawValue: 1 << 3)
    /// **Sharer→viewer only**: this sharer renders and fans out viewer
    /// annotations (draws them on its own overlay + relays to other viewers).
    /// The viewer offers its annotation toolbar only when set — a sharer that
    /// can't render annotations (a future minimal Linux/Windows sharer) would
    /// otherwise leave the viewer drawing local-only scribbles that reach
    /// nobody. Absent ⇒ the viewer hides the drawing tools. Like
    /// `.remoteControl`, purely a sharer capability; a viewer never sets it.
    public static let annotations = ScreenShareCaps(rawValue: 1 << 4)

    /// Every defined capability bit, in one production-side list so
    /// `WireByteRegistryTests` can assert its registry matches this exactly
    /// (single-bit-ness + pairwise disjointness + count). A **new cap MUST be
    /// appended here** in the same change that defines it — a cap that never
    /// joins this list is invisible to the registry's teeth.
    public static let allKnown: [ScreenShareCaps] = [.nack, .receiverReport, .fec, .remoteControl, .annotations]
}

/// RTCP-RR-style receiver report payload (see `ScreenShareControlMessage`
/// `.receiverReport`). Value type so it can round-trip through the wire
/// codecs and be unit-tested without a live socket.
public struct ReceiverReport: Sendable, Equatable {
    /// Fraction of packets lost since the previous report, Q8 fixed point
    /// (loss × 256, clamped to 255). RFC 3550 §6.4.1 "fraction lost".
    public var fracLostQ8: UInt8
    /// Extended highest sequence number received (cycles << 16 | highest).
    public var extHighestSeq: UInt32
    /// Interarrival jitter in RTP timestamp ticks (90 kHz).
    public var jitterTicks: UInt32
    /// The `serverUptimeNs` from the most recent PING this viewer saw, echoed
    /// so the server can measure RTT. 0 if no PING has arrived yet.
    public var lastPingTs: UInt64
    /// Milliseconds the viewer held `lastPingTs` before sending this report,
    /// so the server subtracts its own processing delay from the RTT.
    public var delaySincePingMs: UInt16
    /// Packets this viewer recovered via FEC since its previous report.
    /// Rides the optional 24-byte extended layout (FEC negotiated only);
    /// reads as 0 from the legacy 20-byte (and FEC-era 22-byte) forms.
    /// Recovered packets count as *received* in `fracLostQ8` (residual loss
    /// drives the bitrate arm), so this field is what lets the server's FEC
    /// arm still see raw link loss — the anti-oscillation term (FEC hiding all
    /// loss must not switch FEC off, which would re-trigger the loss it was
    /// hiding).
    public var fecRecovered: UInt16 = 0
    /// Packets this viewer recovered via NACK retransmission since its previous
    /// report. Same role as `fecRecovered` for the FEC arm's raw-loss
    /// reconstruction: a served retransmit counts as *received* (so it drops
    /// residual loss), so without this the arm can't tell a genuinely clean
    /// link from a lossy one NACK is quietly repairing — and FEC would never
    /// gate on a high-RTT link where NACK's per-loss round trip is exactly the
    /// latency FEC's zero-RTT recovery removes. Rides the 24-byte extended
    /// layout; reads as 0 from the 20/22-byte forms.
    public var nackRecovered: UInt16 = 0

    public init(
        fracLostQ8: UInt8, extHighestSeq: UInt32, jitterTicks: UInt32,
        lastPingTs: UInt64, delaySincePingMs: UInt16, fecRecovered: UInt16 = 0,
        nackRecovered: UInt16 = 0
    ) {
        self.fracLostQ8 = fracLostQ8
        self.extHighestSeq = extHighestSeq
        self.jitterTicks = jitterTicks
        self.lastPingTs = lastPingTs
        self.delaySincePingMs = delaySincePingMs
        self.fecRecovered = fecRecovered
        self.nackRecovered = nackRecovered
    }
}

/// 12-byte fixed RTP header (no CSRC list, no extension).
public struct RTPHeader: Sendable {
    public static let size = 12
    /// Dynamic payload type for H.264 (RFC 6184 default).
    public static let h264PayloadType: UInt8 = 96
    /// Dynamic payload type for HEVC. 96 is taken; 97 is the next dynamic
    /// PT and matches what most WebRTC stacks use for HEVC.
    public static let hevcPayloadType: UInt8 = 97
    /// Dynamic payload type for Opus voice. 98 follows H.264 (96) + HEVC
    /// (97). (The `aac` in the name is historical — the voice codec was
    /// AAC-LC before the Opus-only switch; PT 98 is unchanged on the wire.)
    public static let aacPayloadType: UInt8 = 98
    /// Dynamic payload type for shared system/computer audio (Opus),
    /// distinct from voice (98) so viewers demux the two without any
    /// negotiation — the same auto-detect philosophy as video's 96/97.
    /// Viewers that predate the feature reject PT 99 in
    /// `AudioRTPDepacketizer.unpack` / `MultiCodecDepacketizer.ingest`, so
    /// they silently drop it (no torn video/audio).
    public static let systemAudioPayloadType: UInt8 = 99
    /// Every RTP payload type Tailscreen emits, in one production-side list
    /// so `WireByteRegistryTests` can assert its registry table matches this
    /// exactly (count + values + uniqueness). A **new payload type MUST be
    /// appended here** in the same change that defines it — a PT constant
    /// that never joins this list is invisible to the registry's teeth.
    public static let allPayloadTypes: [UInt8] = [
        h264PayloadType, hevcPayloadType, aacPayloadType, systemAudioPayloadType
    ]
    /// Reserved SSRC for the sharer's voice (mic) stream. SSRC spaces are
    /// kept disjoint on purpose: sharer voice owns 0, system audio owns 1,
    /// and viewer-assigned SSRCs start at `firstViewerSSRC` (see the
    /// server's allocation). Pinned by `WireByteRegistryTests`.
    public static let sharerVoiceSSRC: UInt32 = 0
    /// Reserved SSRC for the sharer's system-audio stream (see above).
    public static let systemAudioSSRC: UInt32 = 1
    /// Lowest SSRC the server may assign to a viewer. SSRCs below it are
    /// reserved (sharer voice owns 0, system audio owns `systemAudioSSRC`);
    /// the server's allocation loop draws from `firstViewerSSRC...UInt32.max`.
    /// Pinned by `WireByteRegistryTests` — renumbering breaks the disjoint
    /// SSRC spaces deployed peers rely on.
    public static let firstViewerSSRC: UInt32 = 2
    /// RTP clock rate for the 48 kHz Opus audio path.
    public static let audioClockHz: UInt32 = 48_000
    public static let clockHz: UInt32 = 90_000

    public var marker: Bool
    public var payloadType: UInt8
    public var sequenceNumber: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32

    public func encode(into buffer: inout Data) {
        // V=2, P=0, X=0, CC=0
        buffer.append(0x80)
        buffer.append((marker ? 0x80 : 0x00) | (payloadType & 0x7F))
        buffer.appendBE(sequenceNumber)
        buffer.appendBE(timestamp)
        buffer.appendBE(ssrc)
    }

    /// Parse the fixed RTP header. Returns the header plus the offset at
    /// which the payload starts (skipping CSRC list and extension if any).
    public static func decode(from data: Data) -> (header: RTPHeader, payloadOffset: Int)? {
        guard data.count >= size else { return nil }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        guard (b0 & 0xC0) == 0x80 else { return nil }  // require V=2

        let csrcCount = Int(b0 & 0x0F)
        let hasExt = (b0 & 0x10) != 0
        let marker = (b1 & 0x80) != 0
        let pt = b1 & 0x7F

        let seq = data.readBE(UInt16.self, at: data.startIndex + 2)
        let ts = data.readBE(UInt32.self, at: data.startIndex + 4)
        let ssrc = data.readBE(UInt32.self, at: data.startIndex + 8)

        var offset = size + csrcCount * 4
        if hasExt {
            // [profile:2][length:2 in 32-bit words][... extension ...]
            guard data.count >= offset + 4 else { return nil }
            let extLen = Int(data.readBE(UInt16.self, at: data.startIndex + offset + 2))
            offset += 4 + extLen * 4
        }
        guard data.count >= offset else { return nil }

        let header = RTPHeader(
            marker: marker,
            payloadType: pt,
            sequenceNumber: seq,
            timestamp: ts,
            ssrc: ssrc
        )
        return (header, offset)
    }
}

/// Splits an AVCC-formatted access unit into a sequence of length-prefixed
/// NAL units. Each entry is the raw NAL bytes (NAL header + RBSP), no length
/// prefix.
public enum AVCCParser {
    public static func nalUnits(from avcc: Data, lengthSize: Int = 4) -> [Data] {
        var nals: [Data] = []
        var i = avcc.startIndex
        while i < avcc.endIndex {
            guard avcc.distance(from: i, to: avcc.endIndex) >= lengthSize else { break }
            var len = 0
            for k in 0..<lengthSize {
                len = (len << 8) | Int(avcc[avcc.index(i, offsetBy: k)])
            }
            let nalStart = avcc.index(i, offsetBy: lengthSize)
            guard avcc.distance(from: nalStart, to: avcc.endIndex) >= len else { break }
            let nalEnd = avcc.index(nalStart, offsetBy: len)
            nals.append(Data(avcc[nalStart..<nalEnd]))
            i = nalEnd
        }
        return nals
    }
}

/// Reassembled access unit. Both H.264 and HEVC depacketizers emit this
/// shape; `codec` tells the receiver which parameter-set extraction path
/// to take when `containsIDR` is true.
public struct VideoAccessUnit {
    public let avcc: Data
    public let containsIDR: Bool
    public let timestamp: UInt32
    public let lostBeforeThisAU: Bool
    public let codec: VideoCodec
}

/// RFC 6184 H.264 packetizer. Single NAL mode for small NALs, FU-A for
/// anything that wouldn't fit in one MTU. STAP-A is intentionally not used
/// — keeping the format flat makes the depacketizer trivial.
///
/// Stateful by design: maintains a small pool of `Data` buffers from the
/// previous `packetize` call so each subsequent call can reuse that storage
/// instead of allocating fresh. See `RTPPacketBufferPool` for the safety
/// argument (Data's COW + array-remove-before-mutate gives us in-place
/// reuse when the consumer has dropped its reference, and a clean fresh
/// allocation otherwise — never aliasing).
///
/// `@unchecked Sendable`: callers must serialize access. The
/// screen-share server invokes `packetize` from a single broadcast site
/// chained behind `broadcastTail`, so there is no concurrent use in
/// practice.
public final class H264Packetizer: @unchecked Sendable {
    /// Max bytes of RTP *payload* per packet (excludes the 12-byte RTP header).
    /// Tailscale's WireGuard tunnel typically uses MTU 1280; subtract IPv6+UDP
    /// (40+8) and RTP header (12), leaving ~1220. We use 1100 for headroom.
    public static let maxPayloadBytes = 1100

    private var pool = RTPPacketBufferPool()

    public init() {}

    /// Packetize one access unit's NAL units into RTP packets ready to send.
    /// Sequence numbers run from `startSequence` (incrementing by 1 per
    /// returned packet); the marker bit is set on the last packet only.
    ///
    /// **Buffer lifetime:** returned `Data` values are owned by the caller
    /// (Swift value semantics + COW), but the packetizer holds a pool of
    /// the *previous* call's buffers. When you call `packetize` again, any
    /// buffer from the prior call that is no longer in use (refcount=1 on
    /// the pool side after array removal) has its storage reused in place.
    /// If the consumer still holds a copy, the pool's `removeAll` triggers
    /// COW and the consumer keeps its bytes intact. There is no aliasing
    /// hazard either way.
    public func packetize(
        nals: [Data],
        timestamp: UInt32,
        ssrc: UInt32,
        startSequence: UInt16
    ) -> [Data] {
        var packets: [Data] = []
        // Estimate: one packet per NAL is the lower bound, hint for that.
        packets.reserveCapacity(max(nals.count, pool.recycledCount))

        var seq = startSequence
        for nal in nals {
            guard !nal.isEmpty else { continue }
            if nal.count <= Self.maxPayloadBytes {
                // Single NAL: payload IS the NAL.
                emitPacket(payload: nal, seq: seq, timestamp: timestamp, ssrc: ssrc, into: &packets)
                seq &+= 1
            } else {
                emitFUA(nal: nal, startSeq: &seq, timestamp: timestamp, ssrc: ssrc, into: &packets)
            }
        }

        // Set the marker bit on the final packet (last packet of the AU).
        // We initially emit every packet with marker=0; flipping the one
        // bit at the end is cheaper than threading "isLast" through the
        // emit path.
        if !packets.isEmpty {
            Self.setMarkerBit(on: &packets[packets.count - 1])
        }

        // Hand the new batch back to the pool so the *next* packetize call
        // can recycle these buffers if/when the consumer has released them.
        pool.handOver(packets)
        return packets
    }

    /// Reserve+write an RTP packet for a single-NAL payload using a pooled
    /// buffer when available.
    private func emitPacket(
        payload: Data,
        seq: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        into packets: inout [Data]
    ) {
        let capNeeded = RTPHeader.size + payload.count
        var packet = pool.acquire(minCapacity: capNeeded)
        let header = RTPHeader(
            marker: false,
            payloadType: RTPHeader.h264PayloadType,
            sequenceNumber: seq,
            timestamp: timestamp,
            ssrc: ssrc
        )
        header.encode(into: &packet)
        packet.append(payload)
        packets.append(packet)
    }

    /// RFC 6184 §5.8 FU-A fragmentation. Emits one RTP packet per fragment,
    /// writing the RTP header + FU indicator + FU header + fragment bytes
    /// directly into a pooled buffer (no intermediate `chunks` allocation).
    /// Caller guarantees `nal` is non-empty (it's the same value tested by
    /// `packetize`'s loop header).
    private func emitFUA(
        nal: Data,
        startSeq: inout UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        into packets: inout [Data]
    ) {
        let nalHeader = nal[nal.startIndex]
        let nri = nalHeader & 0x60
        let nalType = nalHeader & 0x1F
        let fuIndicator: UInt8 = nri | 28  // type 28 = FU-A
        let body = nal.dropFirst()

        // Reserve 2 bytes per fragment for the FU header pair.
        let fragSize = Self.maxPayloadBytes - 2
        var offset = body.startIndex
        var first = true
        while offset < body.endIndex {
            let remaining = body.distance(from: offset, to: body.endIndex)
            let take = min(fragSize, remaining)
            let end = body.index(offset, offsetBy: take)
            let isLast = end == body.endIndex

            var fuHeader: UInt8 = nalType
            if first { fuHeader |= 0x80 }  // S bit
            if isLast { fuHeader |= 0x40 }  // E bit (of the fragment, not the AU)

            let capNeeded = RTPHeader.size + 2 + take
            var packet = pool.acquire(minCapacity: capNeeded)
            let header = RTPHeader(
                marker: false,
                payloadType: RTPHeader.h264PayloadType,
                sequenceNumber: startSeq,
                timestamp: timestamp,
                ssrc: ssrc
            )
            header.encode(into: &packet)
            packet.append(fuIndicator)
            packet.append(fuHeader)
            packet.append(body[offset..<end])
            packets.append(packet)

            startSeq &+= 1
            offset = end
            first = false
        }
    }

    /// Sets bit 0x80 of byte 1 of the RTP packet (the marker bit). Used to
    /// flag the final packet of the access unit after we've emitted them
    /// all with marker=0.
    public static func setMarkerBit(on packet: inout Data) {
        guard packet.count > 1 else { return }
        packet[packet.startIndex + 1] |= 0x80
    }
}

/// Small fixed-depth RTP reorder buffer that sits in front of the codec
/// depacketizers.
///
/// Loopback and local-headscale deliver packets in order and lossless, so the
/// depacketizers historically treated *any* sequence-number deviation as loss.
/// That's fine locally, but over a real DERP-relayed WAN — where reordering and
/// duplication are routine — it dropped a whole frame (and fired a PLI) on
/// every reorder event, amplifying loss into a keyframe storm.
///
/// This buffer absorbs reordering up to `maxDepth` packets and silently
/// discards duplicates / late stragglers, only declaring loss when a gap truly
/// can't be filled within the window. It is **latency-free on the happy path**:
/// a packet arriving with the expected sequence number is released immediately;
/// only packets that arrive *ahead* of a gap are briefly held, and only until
/// the gap fills (the reordered packet shows up) or the window overflows. All
/// sequence arithmetic is `&-`/`&+` wrap-safe.
public struct RTPReorderBuffer {
    /// One packet released to the assembler, in ascending sequence order.
    public struct Release {
        let packet: Data
        /// True when a gap was skipped immediately before this packet — the
        /// assembler latches it into the AU's `lostBeforeThisAU` so the viewer
        /// still sends a PLI for genuine loss.
        let lostBefore: Bool
    }

    /// Hard cap on out-of-order packets held while waiting for a gap to fill.
    /// In count-based mode (`gapHoldNs == 0`) this doubles as the abandonment
    /// trigger — ~16 is a few frames' worth, enough to absorb realistic WAN
    /// reordering without adding latency. In time-based (NACK) mode it is a
    /// generous memory bound only: a full keyframe (hundreds of packets) plus
    /// a round-trip of trailing packets must fit, so the client sizes it well
    /// above a keyframe's packet count.
    public let maxDepth: Int

    /// How long to hold an open gap before declaring loss, in nanoseconds.
    /// `0` (default) = pure count-based abandonment (`buffered.count > maxDepth`),
    /// the loopback/reorder-only behavior. When positive (NACK mode), a gap is
    /// held until this elapses so a retransmit arriving ~1 RTT later can still
    /// fill it — the count-based window overflowed in tens of ms at video
    /// bitrate, tearing keyframes long before their retransmits could land.
    /// `maxDepth` remains a hard memory cap on top of the time bound.
    public let gapHoldNs: UInt64

    /// Next sequence number we want to release. nil until the first packet.
    private var nextSeq: UInt16?
    /// Future packets held while waiting for a gap to fill, keyed by seq.
    private var buffered: [UInt16: Data] = [:]
    /// `nowNs` when the current front-gap hold era began (first packet buffered
    /// since `buffered` was last empty). nil while nothing is held. Drives the
    /// `gapHoldNs` deadline; only meaningful when `gapHoldNs > 0`.
    private var oldestGapNs: UInt64?

    public init(maxDepth: Int = 16, gapHoldNs: UInt64 = 0) {
        self.maxDepth = maxDepth
        self.gapHoldNs = gapHoldNs
    }

    public mutating func reset() {
        nextSeq = nil
        buffered.removeAll(keepingCapacity: true)
        oldestGapNs = nil
    }

    /// Count-based convenience: no clock, so time-based holding never applies
    /// (only the `maxDepth` hard cap). Used by the reorder-only / test paths.
    public mutating func push(seq: UInt16, packet: Data) -> [Release] {
        push(seq: seq, packet: packet, nowNs: 0)
    }

    /// Insert one received packet at time `nowNs`; return the packets now
    /// releasable, in order. When `gapHoldNs > 0` an open gap is held until the
    /// deadline elapses (so a NACK retransmit can fill it) or the `maxDepth`
    /// hard cap is hit.
    public mutating func push(seq: UInt16, packet: Data, nowNs: UInt64) -> [Release] {
        guard let want = nextSeq else {
            // First packet of the (re)synced session: release immediately.
            nextSeq = seq &+ 1
            return [Release(packet: packet, lostBefore: false)]
        }

        let ahead = seq &- want  // unsigned distance forward, mod 2^16
        if ahead == 0 {
            // The packet we were waiting for. Release it, then drain any
            // packets that were buffered contiguously ahead of it.
            nextSeq = seq &+ 1
            var out = [Release(packet: packet, lostBefore: false)]
            drainContiguous(into: &out)
            refreshGapClock(nowNs: nowNs)
            return out
        }
        if ahead > UInt16(1 << 15) {
            // "Behind" us in sequence space (distance wraps past the half-way
            // point): a duplicate, or a straggler we already moved past. Drop
            // it — never treat it as corruption.
            return []
        }
        // A future packet: hold it until the gap fills.
        buffered[seq] = packet
        if oldestGapNs == nil { oldestGapNs = nowNs }
        // Hard memory cap always wins — a loss storm must never grow unbounded.
        if buffered.count > maxDepth {
            let out = skipGap()
            refreshGapClock(nowNs: nowNs)
            return out
        }
        // Time bound (NACK mode): give the retransmit its round trip, then
        // give up on the missing packet(s) so genuine loss can't wedge forever.
        if gapHoldNs > 0, let since = oldestGapNs, nowNs &- since >= gapHoldNs {
            let out = skipGap()
            refreshGapClock(nowNs: nowNs)
            return out
        }
        return []
    }

    /// After a drain/skip, restart the hold era for whatever gap now sits at
    /// the front (a different missing sequence than the one just resolved), or
    /// clear it when nothing is held.
    private mutating func refreshGapClock(nowNs: UInt64) {
        oldestGapNs = buffered.isEmpty ? nil : nowNs
    }

    private mutating func drainContiguous(into out: inout [Release]) {
        while let want = nextSeq, let pkt = buffered.removeValue(forKey: want) {
            out.append(Release(packet: pkt, lostBefore: false))
            nextSeq = want &+ 1
        }
    }

    private mutating func skipGap() -> [Release] {
        guard let want = nextSeq,
            let lowest = buffered.keys.min(by: { ($0 &- want) < ($1 &- want) }),
            let pkt = buffered.removeValue(forKey: lowest)
        else { return [] }
        nextSeq = lowest &+ 1
        var out = [Release(packet: pkt, lostBefore: true)]
        drainContiguous(into: &out)
        return out
    }
}

/// Stateful receiver that reassembles RTP packets back into AVCC-formatted
/// access units (length-prefixed NAL units, exactly the shape `VideoDecoder`
/// expects). A `RTPReorderBuffer` in front absorbs WAN reordering/duplication;
/// genuine loss (a gap the reorder window can't fill) still drops the partial
/// AU so the decoder never sees a torn frame, and the caller is expected to
/// send a PLI in response so the encoder issues a fresh IDR.
public final class H264Depacketizer {
    /// Starting reserved capacity for `currentAU`. Sized to cover a typical
    /// 1080p/4K HEVC or H.264 keyframe (~1–2 MB) so the per-NAL `append`
    /// path doesn't cause Data to repeatedly reallocate-and-copy as the AU
    /// grows. Anything larger is handled by Data's normal exponential
    /// growth on overflow.
    public static let initialAUCapacity = 2 * 1024 * 1024  // 2 MB

    /// Starting reserved capacity for `fuBuffer`. Sized to cover the
    /// largest individual NAL we'd realistically see fragmented over FU-A
    /// (one big slice NAL inside a keyframe).
    public static let initialFUCapacity = 256 * 1024  // 256 KB

    private var ssrc: UInt32?
    private var currentTimestamp: UInt32?
    private var currentAU: Data
    private var currentHasIDR: Bool = false
    private var currentAUCorrupted: Bool = false
    private var fuBuffer: Data
    private var fuNALHeader: UInt8 = 0
    private var inFU: Bool = false
    private var pendingLossSignal: Bool = false
    /// Absorbs WAN packet reordering/duplication before assembly (see
    /// `RTPReorderBuffer`). Owns all sequence-number tracking now.
    private var reorder: RTPReorderBuffer
    /// Completed AUs awaiting return. A single `ingest` can complete more than
    /// one AU when a late packet unblocks a run of buffered packets spanning a
    /// frame boundary; we return them one per `ingest` call, in order, to keep
    /// the `ingest(_:) -> VideoAccessUnit?` contract the caller relies on.
    private var readyQueue: [VideoAccessUnit] = []

    public init(reorderDepth: Int = 16, gapHoldNs: UInt64 = 0) {
        var au = Data()
        au.reserveCapacity(Self.initialAUCapacity)
        self.currentAU = au

        var fu = Data()
        fu.reserveCapacity(Self.initialFUCapacity)
        self.fuBuffer = fu

        self.reorder = RTPReorderBuffer(maxDepth: reorderDepth, gapHoldNs: gapHoldNs)
    }

    /// Feed one received RTP packet (no clock — count-based reorder only).
    public func ingest(_ packet: Data) -> VideoAccessUnit? {
        ingest(packet, nowNs: 0)
    }

    /// Feed one received RTP packet at time `nowNs`. Returns a completed AU
    /// once the marker bit (or a timestamp change) signals end-of-frame; nil
    /// otherwise. `nowNs` drives the reorder buffer's time-based gap hold in
    /// NACK mode so a retransmit arriving ~1 RTT later still fills the gap.
    public func ingest(_ packet: Data, nowNs: UInt64) -> VideoAccessUnit? {
        guard let (header, _) = RTPHeader.decode(from: packet) else { return nil }
        guard header.payloadType == RTPHeader.h264PayloadType else { return nil }

        // Lock onto the first SSRC we see; ignore packets from a different
        // session (could happen if the sender restarts).
        if let known = ssrc, known != header.ssrc {
            reset()
            ssrc = header.ssrc
        } else if ssrc == nil {
            ssrc = header.ssrc
        }

        // Route through the reorder buffer; assemble whatever it releases, in
        // order. In-order packets release immediately (no added latency).
        for release in reorder.push(seq: header.sequenceNumber, packet: packet, nowNs: nowNs) {
            assemble(release.packet, lostBefore: release.lostBefore)
        }
        return readyQueue.isEmpty ? nil : readyQueue.removeFirst()
    }

    /// Assemble one in-sequence packet into the current AU, appending any
    /// completed AU to `readyQueue`. `lostBefore` is set by the reorder buffer
    /// when it skipped an unfillable gap immediately before this packet.
    /// Drain access units completed but not yet returned by `ingest`. A single
    /// `ingest` returns at most one AU, but a late packet that unblocks a run
    /// of buffered packets can complete several at once; production reads the
    /// extras one per subsequent `ingest`, while a test that's finished feeding
    /// a stream uses this to flush the tail.
    public func drainReady() -> [VideoAccessUnit] {
        let out = readyQueue
        readyQueue.removeAll(keepingCapacity: true)
        return out
    }

    private func assemble(_ packet: Data, lostBefore: Bool) {
        guard let (header, payloadOffset) = RTPHeader.decode(from: packet) else { return }

        if lostBefore {
            currentAUCorrupted = true
            pendingLossSignal = true
            inFU = false
            fuBuffer.removeAll(keepingCapacity: true)
        }

        // Timestamp change without a marker means the previous AU's marker
        // packet was lost. Discard whatever we accumulated and start fresh.
        if let prevTs = currentTimestamp, prevTs != header.timestamp {
            currentAUCorrupted = true
            currentAU.removeAll(keepingCapacity: true)
            currentHasIDR = false
            inFU = false
            fuBuffer.removeAll(keepingCapacity: true)
            pendingLossSignal = true
        }
        currentTimestamp = header.timestamp

        let payload = packet[packet.index(packet.startIndex, offsetBy: payloadOffset)..<packet.endIndex]
        if payload.isEmpty {
            currentAUCorrupted = true
        } else {
            handlePayload(Data(payload))
        }

        if header.marker, let au = flushAU(timestamp: header.timestamp) {
            readyQueue.append(au)
        }
    }

    private func handlePayload(_ payload: Data) {
        let nalHeader = payload[payload.startIndex]
        let nalType = nalHeader & 0x1F

        switch nalType {
        case 1...23:
            // Single NAL packet: payload IS the complete NAL.
            appendNAL(payload)
        case 28:
            // FU-A: payload is [FU indicator][FU header][fragment...].
            guard payload.count >= 2 else {
                currentAUCorrupted = true
                return
            }
            let fuIndicator = payload[payload.startIndex]
            let fuHeader = payload[payload.startIndex + 1]
            let isStart = (fuHeader & 0x80) != 0
            let isEnd = (fuHeader & 0x40) != 0
            let originalType = fuHeader & 0x1F
            let fragStart = payload.index(payload.startIndex, offsetBy: 2)
            let fragment = payload[fragStart..<payload.endIndex]

            if isStart {
                fuBuffer.removeAll(keepingCapacity: true)
                // Reconstruct original NAL header: F+NRI from FU indicator, type from FU header.
                fuNALHeader = (fuIndicator & 0xE0) | originalType
                fuBuffer.append(fuNALHeader)
                fuBuffer.append(fragment)
                inFU = true
            } else if inFU {
                fuBuffer.append(fragment)
            } else {
                // Got a middle/end fragment without start — we missed packets.
                currentAUCorrupted = true
                return
            }

            if isEnd && inFU {
                appendNAL(fuBuffer)
                fuBuffer.removeAll(keepingCapacity: true)
                inFU = false
            }
        default:
            // STAP-A (24), MTAP (26-27), FU-B (29), reserved — we never emit
            // these, so unexpected. Mark AU corrupted rather than guess.
            currentAUCorrupted = true
        }
    }

    private func appendNAL(_ nal: Data) {
        let nalType = nal.first.map { $0 & 0x1F } ?? 0
        if nalType == 5 { currentHasIDR = true }
        // AVCC: 4-byte big-endian length prefix then NAL bytes.
        let len = UInt32(nal.count)
        currentAU.appendBE(len)
        currentAU.append(nal)
    }

    private func flushAU(timestamp: UInt32) -> VideoAccessUnit? {
        let wasCorrupted = currentAUCorrupted || currentAU.isEmpty
        let lostBefore = pendingLossSignal
        let avcc = currentAU
        let hasIDR = currentHasIDR

        // Replace `currentAU` with a freshly-reserved buffer so the next AU
        // doesn't pay quadratic-style reallocation cost as `append` fills
        // it. We can't `removeAll(keepingCapacity:)` here because `avcc`
        // shares this buffer via COW; mutating it would either trigger COW
        // (defeating the reuse) or alias bytes the consumer is about to
        // read. A fresh allocation is the safe, correct choice.
        var fresh = Data()
        fresh.reserveCapacity(Self.initialAUCapacity)
        currentAU = fresh
        currentHasIDR = false
        currentAUCorrupted = false
        inFU = false
        fuBuffer.removeAll(keepingCapacity: true)
        currentTimestamp = nil

        if wasCorrupted {
            // Drop the AU but keep the loss flag latched so the next clean
            // AU still carries it — the caller uses that to drive PLI.
            return nil
        }
        pendingLossSignal = false
        return VideoAccessUnit(
            avcc: avcc,
            containsIDR: hasIDR,
            timestamp: timestamp,
            lostBeforeThisAU: lostBefore,
            codec: .h264
        )
    }

    /// Discard all in-flight state. Called on SSRC change.
    private func reset() {
        reorder.reset()
        readyQueue.removeAll(keepingCapacity: true)
        currentTimestamp = nil
        currentAU.removeAll(keepingCapacity: true)
        currentHasIDR = false
        currentAUCorrupted = false
        fuBuffer.removeAll(keepingCapacity: true)
        inFU = false
        pendingLossSignal = false
    }
}

/// RFC 7798 HEVC packetizer. Same shape as the H.264 path — Single NAL for
/// small NALs, FU mode for anything that wouldn't fit in one MTU. AP
/// (aggregation packets) and PACI are intentionally unused; the depacketizer
/// is correspondingly simpler.
///
/// Buffer-pool semantics mirror `H264Packetizer`. Same `@unchecked
/// Sendable` rationale: callers must serialize access; the screen-share
/// server only invokes `packetize` from a single broadcast site chained
/// behind `broadcastTail`.
public final class H265Packetizer: @unchecked Sendable {
    public static let maxPayloadBytes = H264Packetizer.maxPayloadBytes

    private var pool = RTPPacketBufferPool()

    public init() {}

    public func packetize(
        nals: [Data],
        timestamp: UInt32,
        ssrc: UInt32,
        startSequence: UInt16
    ) -> [Data] {
        var packets: [Data] = []
        packets.reserveCapacity(max(nals.count, pool.recycledCount))

        var seq = startSequence
        for nal in nals {
            guard nal.count >= 2 else { continue }
            if nal.count <= Self.maxPayloadBytes {
                emitPacket(payload: nal, seq: seq, timestamp: timestamp, ssrc: ssrc, into: &packets)
                seq &+= 1
            } else {
                emitFU(nal: nal, startSeq: &seq, timestamp: timestamp, ssrc: ssrc, into: &packets)
            }
        }

        if !packets.isEmpty {
            H264Packetizer.setMarkerBit(on: &packets[packets.count - 1])
        }

        pool.handOver(packets)
        return packets
    }

    private func emitPacket(
        payload: Data,
        seq: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        into packets: inout [Data]
    ) {
        let capNeeded = RTPHeader.size + payload.count
        var packet = pool.acquire(minCapacity: capNeeded)
        let header = RTPHeader(
            marker: false,
            payloadType: RTPHeader.hevcPayloadType,
            sequenceNumber: seq,
            timestamp: timestamp,
            ssrc: ssrc
        )
        header.encode(into: &packet)
        packet.append(payload)
        packets.append(packet)
    }

    /// RFC 7798 §4.4.3 FU fragmentation. The two-byte payload header has
    /// the FU type (49); the original NAL type rides in the 1-byte FU
    /// header that follows. LayerId and TID are preserved from the input
    /// NAL header so reassembly reconstructs an identical original NAL.
    private func emitFU(
        nal: Data,
        startSeq: inout UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        into packets: inout [Data]
    ) {
        let nh0 = nal[nal.startIndex]
        let nh1 = nal[nal.index(nal.startIndex, offsetBy: 1)]
        let originalType = (nh0 >> 1) & 0x3F
        let fBit = nh0 & 0x80
        let layerIdHi = nh0 & 0x01  // top bit of LayerId rides in byte 0 LSB

        // Build the PayloadHdr: F (preserved) | Type=49 | LayerId top bit
        let payloadHdr0: UInt8 = fBit | (49 << 1) | layerIdHi
        let payloadHdr1: UInt8 = nh1  // remaining LayerId + TID

        let body = nal.dropFirst(2)
        // Reserve 3 bytes per fragment for PayloadHdr (2) + FU header (1).
        let fragSize = Self.maxPayloadBytes - 3
        var offset = body.startIndex
        var first = true
        while offset < body.endIndex {
            let remaining = body.distance(from: offset, to: body.endIndex)
            let take = min(fragSize, remaining)
            let end = body.index(offset, offsetBy: take)
            let isLast = end == body.endIndex

            var fuHeader: UInt8 = originalType & 0x3F
            if first { fuHeader |= 0x80 }  // S bit
            if isLast { fuHeader |= 0x40 }  // E bit (fragment, not AU)

            let capNeeded = RTPHeader.size + 3 + take
            var packet = pool.acquire(minCapacity: capNeeded)
            let header = RTPHeader(
                marker: false,
                payloadType: RTPHeader.hevcPayloadType,
                sequenceNumber: startSeq,
                timestamp: timestamp,
                ssrc: ssrc
            )
            header.encode(into: &packet)
            packet.append(payloadHdr0)
            packet.append(payloadHdr1)
            packet.append(fuHeader)
            packet.append(body[offset..<end])
            packets.append(packet)

            startSeq &+= 1
            offset = end
            first = false
        }
    }
}

/// HEVC RFC 7798 depacketizer. Mirrors H264Depacketizer line for line; the
/// only structural differences are the 2-byte NAL header, the 6-bit type
/// field, and FU type 49 (vs FU-A 28 for H.264).
public final class H265Depacketizer {
    /// See `H264Depacketizer.initialAUCapacity`.
    public static let initialAUCapacity = H264Depacketizer.initialAUCapacity
    public static let initialFUCapacity = H264Depacketizer.initialFUCapacity

    private var ssrc: UInt32?
    private var currentTimestamp: UInt32?
    private var currentAU: Data
    private var currentHasIDR: Bool = false
    private var currentAUCorrupted: Bool = false
    private var fuBuffer: Data
    private var inFU: Bool = false
    private var pendingLossSignal: Bool = false
    /// See `H264Depacketizer.reorder` / `.readyQueue`.
    private var reorder: RTPReorderBuffer
    private var readyQueue: [VideoAccessUnit] = []

    public init(reorderDepth: Int = 16, gapHoldNs: UInt64 = 0) {
        var au = Data()
        au.reserveCapacity(Self.initialAUCapacity)
        self.currentAU = au

        var fu = Data()
        fu.reserveCapacity(Self.initialFUCapacity)
        self.fuBuffer = fu

        self.reorder = RTPReorderBuffer(maxDepth: reorderDepth, gapHoldNs: gapHoldNs)
    }

    /// Feed one received RTP packet (no clock — count-based reorder only).
    public func ingest(_ packet: Data) -> VideoAccessUnit? {
        ingest(packet, nowNs: 0)
    }

    /// See `H264Depacketizer.ingest(_:nowNs:)` — `nowNs` drives the reorder
    /// buffer's time-based gap hold in NACK mode.
    public func ingest(_ packet: Data, nowNs: UInt64) -> VideoAccessUnit? {
        guard let (header, _) = RTPHeader.decode(from: packet) else { return nil }
        guard header.payloadType == RTPHeader.hevcPayloadType else { return nil }

        if let known = ssrc, known != header.ssrc {
            reset()
            ssrc = header.ssrc
        } else if ssrc == nil {
            ssrc = header.ssrc
        }

        for release in reorder.push(seq: header.sequenceNumber, packet: packet, nowNs: nowNs) {
            assemble(release.packet, lostBefore: release.lostBefore)
        }
        return readyQueue.isEmpty ? nil : readyQueue.removeFirst()
    }

    /// Drain access units completed but not yet returned by `ingest`. A single
    /// `ingest` returns at most one AU, but a late packet that unblocks a run
    /// of buffered packets can complete several at once; production reads the
    /// extras one per subsequent `ingest`, while a test that's finished feeding
    /// a stream uses this to flush the tail.
    public func drainReady() -> [VideoAccessUnit] {
        let out = readyQueue
        readyQueue.removeAll(keepingCapacity: true)
        return out
    }

    private func assemble(_ packet: Data, lostBefore: Bool) {
        guard let (header, payloadOffset) = RTPHeader.decode(from: packet) else { return }

        if lostBefore {
            currentAUCorrupted = true
            pendingLossSignal = true
            inFU = false
            fuBuffer.removeAll(keepingCapacity: true)
        }

        if let prevTs = currentTimestamp, prevTs != header.timestamp {
            currentAUCorrupted = true
            currentAU.removeAll(keepingCapacity: true)
            currentHasIDR = false
            inFU = false
            fuBuffer.removeAll(keepingCapacity: true)
            pendingLossSignal = true
        }
        currentTimestamp = header.timestamp

        let payload = packet[packet.index(packet.startIndex, offsetBy: payloadOffset)..<packet.endIndex]
        if payload.count < 2 {
            currentAUCorrupted = true
        } else {
            handlePayload(Data(payload))
        }

        if header.marker, let au = flushAU(timestamp: header.timestamp) {
            readyQueue.append(au)
        }
    }

    private func handlePayload(_ payload: Data) {
        let h0 = payload[payload.startIndex]
        let nalType = (h0 >> 1) & 0x3F  // 6-bit HEVC NAL type

        switch nalType {
        case 0...47:
            // Single NAL packet: payload IS the complete NAL (2-byte header + body).
            appendNAL(payload)
        case 49:
            // FU: payload is [PayloadHdr:2][FU header:1][fragment...].
            guard payload.count >= 3 else {
                currentAUCorrupted = true
                return
            }
            let payloadHdr0 = payload[payload.startIndex]
            let payloadHdr1 = payload[payload.index(payload.startIndex, offsetBy: 1)]
            let fuHeader = payload[payload.index(payload.startIndex, offsetBy: 2)]
            let isStart = (fuHeader & 0x80) != 0
            let isEnd = (fuHeader & 0x40) != 0
            let originalType = fuHeader & 0x3F
            let fragStart = payload.index(payload.startIndex, offsetBy: 3)
            let fragment = payload[fragStart..<payload.endIndex]

            if isStart {
                fuBuffer.removeAll(keepingCapacity: true)
                // Reconstruct the original NAL header: F + LayerId top bit
                // come from PayloadHdr byte 0; original type goes in bits
                // 1-6 of the same byte. Byte 1 (rest of LayerId + TID)
                // passes through unchanged.
                let fBit = payloadHdr0 & 0x80
                let layerIdHi = payloadHdr0 & 0x01
                let originalH0: UInt8 = fBit | ((originalType & 0x3F) << 1) | layerIdHi
                fuBuffer.append(originalH0)
                fuBuffer.append(payloadHdr1)
                fuBuffer.append(fragment)
                inFU = true
            } else if inFU {
                fuBuffer.append(fragment)
            } else {
                currentAUCorrupted = true
                return
            }

            if isEnd && inFU {
                appendNAL(fuBuffer)
                fuBuffer.removeAll(keepingCapacity: true)
                inFU = false
            }
        default:
            // 48 = AP, 50 = PACI, 51-63 reserved. We never emit these;
            // mark the AU corrupted rather than try to handle them.
            currentAUCorrupted = true
        }
    }

    private func appendNAL(_ nal: Data) {
        guard nal.count >= 1 else { return }
        let nalType = (nal[nal.startIndex] >> 1) & 0x3F
        // 16..21 are IRAP NAL types (BLA/IDR/CRA). VT emits IDR_W_RADL
        // (type 19) for forced keyframes; treat the whole IRAP range as
        // "this AU is decodable from scratch".
        if (16...21).contains(nalType) { currentHasIDR = true }
        let len = UInt32(nal.count)
        currentAU.appendBE(len)
        currentAU.append(nal)
    }

    private func flushAU(timestamp: UInt32) -> VideoAccessUnit? {
        let wasCorrupted = currentAUCorrupted || currentAU.isEmpty
        let lostBefore = pendingLossSignal
        let avcc = currentAU
        let hasIDR = currentHasIDR

        // See `H264Depacketizer.flushAU` for the rationale: we hand the
        // accumulated `currentAU` storage to the caller (via `avcc`) and
        // pre-reserve a fresh buffer of the same capacity for the next
        // AU. This keeps the per-NAL `append` path off Data's quadratic
        // grow-and-copy escalator for large keyframes.
        var fresh = Data()
        fresh.reserveCapacity(Self.initialAUCapacity)
        currentAU = fresh
        currentHasIDR = false
        currentAUCorrupted = false
        inFU = false
        fuBuffer.removeAll(keepingCapacity: true)
        currentTimestamp = nil

        if wasCorrupted {
            return nil
        }
        pendingLossSignal = false
        return VideoAccessUnit(
            avcc: avcc,
            containsIDR: hasIDR,
            timestamp: timestamp,
            lostBeforeThisAU: lostBefore,
            codec: .hevc
        )
    }

    private func reset() {
        reorder.reset()
        readyQueue.removeAll(keepingCapacity: true)
        currentTimestamp = nil
        currentAU.removeAll(keepingCapacity: true)
        currentHasIDR = false
        currentAUCorrupted = false
        fuBuffer.removeAll(keepingCapacity: true)
        inFU = false
        pendingLossSignal = false
    }
}

/// Routes incoming RTP packets to the right depacketizer based on the
/// payload type. Used by the viewer so we don't need a separate negotiation
/// step — whichever codec the server picked, the receiver discovers it
/// from the first packet's PT.
public final class MultiCodecDepacketizer {
    private let h264: H264Depacketizer
    private let h265: H265Depacketizer

    /// `reorderDepth` sizes each codec's `RTPReorderBuffer`. The viewer plumbs
    /// a deeper window when the server advertised NACK support — retransmits
    /// have to land before the window overflows, and the default 16 packets is
    /// only a few frames (shallower than one WAN RTT). Defaults to the
    /// happy-path 16 for legacy / non-NACK sessions.
    /// `gapHoldNs` (NACK mode) holds an open gap by time so a retransmit
    /// arriving ~1 RTT later fills it before the AU is torn; `0` (default) is
    /// the count-based happy path. See `RTPReorderBuffer.gapHoldNs`.
    public init(reorderDepth: Int = 16, gapHoldNs: UInt64 = 0) {
        self.h264 = H264Depacketizer(reorderDepth: reorderDepth, gapHoldNs: gapHoldNs)
        self.h265 = H265Depacketizer(reorderDepth: reorderDepth, gapHoldNs: gapHoldNs)
    }

    /// Feed one received RTP packet (no clock — count-based reorder only).
    public func ingest(_ packet: Data) -> VideoAccessUnit? {
        ingest(packet, nowNs: 0)
    }

    /// Feed one received RTP packet at time `nowNs` — drives the reorder
    /// buffer's time-based gap hold in NACK mode.
    public func ingest(_ packet: Data, nowNs: UInt64) -> VideoAccessUnit? {
        guard let (header, _) = RTPHeader.decode(from: packet) else { return nil }
        switch header.payloadType {
        case RTPHeader.h264PayloadType:
            return h264.ingest(packet, nowNs: nowNs)
        case RTPHeader.hevcPayloadType:
            return h265.ingest(packet, nowNs: nowNs)
        default:
            return nil
        }
    }

    /// Drain access units completed but not yet returned by `ingest` (a single
    /// late packet — including an FEC recovery — can unblock a run of buffered
    /// packets, but `ingest` returns only the first). Only the active codec's
    /// depacketizer holds anything; the other's queue is empty.
    public func drainReady() -> [VideoAccessUnit] {
        h264.drainReady() + h265.drainReady()
    }
}

extension Data {
    fileprivate mutating func appendBE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    fileprivate mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    fileprivate func readBE(_: UInt16.Type, at index: Data.Index) -> UInt16 {
        let b0 = UInt16(self[index])
        let b1 = UInt16(self[self.index(index, offsetBy: 1)])
        return (b0 << 8) | b1
    }

    fileprivate func readBE(_: UInt32.Type, at index: Data.Index) -> UInt32 {
        let b0 = UInt32(self[index])
        let b1 = UInt32(self[self.index(index, offsetBy: 1)])
        let b2 = UInt32(self[self.index(index, offsetBy: 2)])
        let b3 = UInt32(self[self.index(index, offsetBy: 3)])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    fileprivate mutating func appendBE(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    fileprivate func readBE(_: UInt64.Type, at index: Data.Index) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0..<8 {
            value = (value << 8) | UInt64(self[self.index(index, offsetBy: offset)])
        }
        return value
    }
}
