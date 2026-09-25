// The sharer's `transport.summary` row for one viewer and one sweep window,
// as a pure function on `TailscaleScreenShareServer`. The adaptive sweep that
// records it can't run in a test (no-ops without a capture helper), so the
// field set is pinned here by `SharerTransportSummaryTests`.

import Foundation
import TailscreenProtocol

extension TailscaleScreenShareServer {

    /// What the sweep knows about one viewer at the end of a window: the
    /// feedback it sent (PLIs, its last receiver report and when), what the
    /// sharer did for it (retransmits, its share of parity), and what the
    /// sharer could not do (frames dropped behind a stalled send).
    public struct ViewerTransportSample: Equatable, Sendable {
        /// PLIs received from this viewer in the window.
        public var pliCount: Int = 0
        /// `fracLostQ8` of the most recent receiver report, undecayed —
        /// carried separately from `rr_age_ms` so a stale report reads as
        /// stale, not as "no loss".
        public var lossFractionQ8: Int = 0
        /// RTT derived from the most recent receiver report; 0 before one.
        public var rttNs: UInt64 = 0
        /// Clock reading of the most recent receiver report; 0 if none yet.
        public var lastRRAtNs: UInt64 = 0
        /// Retransmits served to this viewer in the window.
        public var nackServed: Int = 0
        /// Packets this viewer reported recovering via FEC in the window.
        public var fecRecovered: Int = 0
        /// Packets this viewer reported recovering via NACK in the window.
        public var nackRecovered: Int = 0
        /// Video packets planned for this viewer in the window.
        public var packetsSent: Int = 0
        /// Audio RTP packets accepted FROM this viewer in the window — the
        /// upstream half, which this row had none of.
        public var audioPacketsReceived: Int = 0
        /// Audio RTP packets from this viewer rejected by the source-SSRC
        /// anti-spoof gate in the window.
        public var audioPacketsRejected: Int = 0
        /// Cumulative video frames dropped behind this viewer's stalled send.
        public var droppedVideoFrames: Int = 0
        /// Cumulative audio frames dropped behind this viewer's stalled send.
        public var droppedAudioFrames: Int = 0
        /// The sweep's health verdict for this viewer this window.
        public var health: ViewerHealth = .good
        /// Whether this viewer is currently gated for parity delivery.
        public var fecGated: Bool = false

        public init(
            pliCount: Int = 0, lossFractionQ8: Int = 0, rttNs: UInt64 = 0,
            lastRRAtNs: UInt64 = 0, nackServed: Int = 0, fecRecovered: Int = 0,
            nackRecovered: Int = 0, packetsSent: Int = 0,
            audioPacketsReceived: Int = 0, audioPacketsRejected: Int = 0,
            droppedVideoFrames: Int = 0, droppedAudioFrames: Int = 0,
            health: ViewerHealth = .good, fecGated: Bool = false
        ) {
            self.pliCount = pliCount
            self.lossFractionQ8 = lossFractionQ8
            self.rttNs = rttNs
            self.lastRRAtNs = lastRRAtNs
            self.nackServed = nackServed
            self.fecRecovered = fecRecovered
            self.nackRecovered = nackRecovered
            self.packetsSent = packetsSent
            self.audioPacketsReceived = audioPacketsReceived
            self.audioPacketsRejected = audioPacketsRejected
            self.droppedVideoFrames = droppedVideoFrames
            self.droppedAudioFrames = droppedAudioFrames
            self.health = health
            self.fecGated = fecGated
        }
    }

    /// The share-wide state a viewer's row is read against: the tier the
    /// encoder is at and whether parity is being generated at all.
    public struct ShareTransportState: Equatable, Sendable {
        /// The congestion-controlled bitrate, before FEC compensation.
        public var bitrateBps: Int
        /// The baseline the sweep recovers toward (formula clamped by the
        /// user's ceiling), so a row says how far below it the share is.
        public var baselineBps: Int
        /// Current capture frame-rate tier (60 / 30 / 15).
        public var fpsTier: Int
        /// FEC group size the encoder is compensated for; 0 = parity off.
        public var fecGroupSize: Int

        public init(bitrateBps: Int, baselineBps: Int, fpsTier: Int, fecGroupSize: Int) {
            self.bitrateBps = bitrateBps
            self.baselineBps = baselineBps
            self.fpsTier = fpsTier
            self.fecGroupSize = fecGroupSize
        }
    }

    /// When a row is taken and how long it covers.
    ///
    /// Two durations, on purpose: `nominalNs` is the sweep's window (the
    /// `rr_fresh` freshness threshold); `elapsedNs` is the actual time since
    /// the previous row, reported as `window_ms` — the sweep's work between
    /// sleeps means the real interval runs longer than nominal, and claiming
    /// the nominal value would understate every derived rate.
    public struct SummaryWindow: Equatable, Sendable {
        /// Uptime reading the row is taken at; ages are measured from it.
        public var nowNs: UInt64
        /// The sweep's nominal window, the freshness threshold.
        public var nominalNs: UInt64
        /// Measured time since the previous row.
        public var elapsedNs: UInt64

        public init(nowNs: UInt64, nominalNs: UInt64, elapsedNs: UInt64) {
            self.nowNs = nowNs
            self.nominalNs = nominalNs
            self.elapsedNs = elapsedNs
        }
    }

    /// Viewer annotations seen on the framed control channel in one window.
    public struct AnnotationCounters: Equatable, Sendable {
        /// Ops that passed the admitted-viewer gate and reached the sharer's
        /// own overlay.
        public var applied: Int = 0
        /// Ops the admitted-viewer gate rejected — a pending, denied,
        /// blocked or expelled peer, or one whose address did not reduce to
        /// an admitted viewer's.
        public var dropped: Int = 0
        /// Ops fanned out to the other viewers.
        public var relayed: Int = 0

        public init(applied: Int = 0, dropped: Int = 0, relayed: Int = 0) {
            self.applied = applied
            self.dropped = dropped
            self.relayed = relayed
        }

        /// Nothing crossed the channel this window.
        public var isEmpty: Bool { applied == 0 && dropped == 0 && relayed == 0 }
    }

    /// The `annotation.summary` fields for one window. Separates three
    /// causes of "I drew and the sharer saw nothing": `applied` climbing
    /// means strokes reached the overlay; `dropped` climbing means the
    /// admitted-viewer gate refused them; no row at all means nothing reached
    /// this machine.
    public static func annotationSummaryFields(
        counters: AnnotationCounters, windowNs: UInt64
    ) -> [String: DiagnosticValue] {
        [
            "window_ms": DiagnosticValue(windowNs / 1_000_000),
            "applied": DiagnosticValue(counters.applied),
            "dropped": DiagnosticValue(counters.dropped),
            "relayed": DiagnosticValue(counters.relayed)
        ]
    }

    /// The `transport.summary` fields for one viewer.
    ///
    /// `rr_received` says whether this viewer has EVER sent a receiver
    /// report; `rr_age_ms` how long ago; `rr_fresh` is the sweep's own
    /// freshness verdict — without these a viewer whose reports quietly
    /// stopped arriving looked identical to a clean share.
    ///
    /// `loss_q8` is the last report's residual loss undecayed; `raw_loss_q8`
    /// adds back what FEC/NACK recovered (the number the FEC arm gates on).
    /// Both Q8 like the wire field, `loss_pct` alongside for convenience.
    ///
    /// `audio_packets_in`/`audio_rejected_in` distinguish "audio never
    /// reached the wire" from "audio arrived and was rejected by the
    /// source-SSRC gate" — both otherwise look like silence from here.
    ///
    /// The window carries two durations — see ``SummaryWindow``.
    public static func transportSummaryFields(
        addr: String,
        sample: ViewerTransportSample,
        share: ShareTransportState,
        window: SummaryWindow
    ) -> [String: DiagnosticValue] {
        let nowNs = window.nowNs
        let rrReceived = sample.lastRRAtNs != 0
        let rrAgeNs = rrReceived && nowNs >= sample.lastRRAtNs ? nowNs - sample.lastRRAtNs : 0
        let rrFresh = rrReceived && rrAgeNs < window.nominalNs
        let rawLossQ8 = min(
            255,
            sample.lossFractionQ8
                + fecRecoveredQ8(
                    recovered: sample.fecRecovered + sample.nackRecovered,
                    expectedPackets: sample.packetsSent))
        var fields: [String: DiagnosticValue] = [
            "addr": .string(addr),
            "window_ms": DiagnosticValue(window.elapsedNs / 1_000_000),
            "plis": DiagnosticValue(sample.pliCount),
            "rr_received": .bool(rrReceived),
            "rr_fresh": .bool(rrFresh),
            "loss_q8": DiagnosticValue(sample.lossFractionQ8),
            "loss_pct": .double((Double(sample.lossFractionQ8) * 100 / 255 * 10).rounded() / 10),
            "raw_loss_q8": DiagnosticValue(rawLossQ8),
            "rtt_ms": DiagnosticValue(sample.rttNs / 1_000_000),
            "nack_served": DiagnosticValue(sample.nackServed),
            "fec_recovered": DiagnosticValue(sample.fecRecovered),
            "nack_recovered": DiagnosticValue(sample.nackRecovered),
            "packets_sent": DiagnosticValue(sample.packetsSent),
            "audio_packets_in": DiagnosticValue(sample.audioPacketsReceived),
            "audio_rejected_in": DiagnosticValue(sample.audioPacketsRejected),
            "video_drops_total": DiagnosticValue(sample.droppedVideoFrames),
            "audio_drops_total": DiagnosticValue(sample.droppedAudioFrames),
            "health": .string(sample.health.rawValue),
            "fec_gated": .bool(sample.fecGated),
            "bitrate_kbps": DiagnosticValue(share.bitrateBps / 1000),
            "baseline_kbps": DiagnosticValue(share.baselineBps / 1000),
            "fps_tier": DiagnosticValue(share.fpsTier),
            "fec_group_size": DiagnosticValue(share.fecGroupSize)
        ]
        // Absent rather than 0 when there has never been a report: an age of
        // zero reads as "just now", which is the opposite of the truth.
        if rrReceived {
            fields["rr_age_ms"] = DiagnosticValue(rrAgeNs / 1_000_000)
        }
        return fields
    }
}
