import Foundation

/// Interleaving two or more sides of one session into a single ordered
/// story — the payoff for recording at all. See
/// `.claude/rules/diagnostics.md`'s "The clock problem" for the full picture.
///
/// Two machines' wall clocks disagree, so sorting raw timestamps can show an
/// ack before its message. The fix uses the handshake's four timestamps,
/// exactly the NTP offset exchange:
///
/// ```text
///   viewer  ──HELLO────────▶  t1 sent (viewer clock)   t2 received (sharer clock)
///   sharer  ◀─HELLO_ACK────   t4 received (viewer)     t3 sent (sharer clock)
/// ```
///
/// `offset = ((t2 - t1) + (t3 - t4)) / 2`, paired on the SSRC the sharer
/// assigns in HELLO_ACK. Always reported in ``Timeline/clockNotes``, never silently applied.
public enum DiagnosticsMerge {

    /// One event in a merged timeline, tagged with where it came from.
    public struct Line: Sendable, Equatable {
        /// The bundle this came from, by device name.
        public var device: String
        public var role: DiagnosticRole
        /// The event, with `wallClock` **adjusted** onto the reference
        /// timeline. ``originalWallClock`` keeps what the device itself said.
        public var event: DiagnosticEvent
        /// The timestamp as recorded, before skew correction.
        public var originalWallClock: Date
        /// Seconds added to this device's clock to reach the reference
        /// timeline. Zero for the reference device and whenever no estimate
        /// could be made.
        public var appliedOffsetSeconds: TimeInterval

        public init(
            device: String,
            role: DiagnosticRole,
            event: DiagnosticEvent,
            originalWallClock: Date,
            appliedOffsetSeconds: TimeInterval
        ) {
            self.device = device
            self.role = role
            self.event = event
            self.originalWallClock = originalWallClock
            self.appliedOffsetSeconds = appliedOffsetSeconds
        }
    }

    /// A hole in one device's stream, where the recorder evicted events. So a
    /// reader doesn't read the retained prologue and ring as adjacent and
    /// infer causality across the gap. Located from a `seq` discontinuity
    /// (dense by construction), which says where, not just how many.
    public struct Gap: Sendable, Equatable {
        public var device: String
        /// How many events the recorder dropped here.
        public var missing: UInt64
        /// The corrected time of the first event AFTER the hole, which is where
        /// the marker belongs in the merged order.
        public var at: Date

        public init(device: String, missing: UInt64, at: Date) {
            self.device = device
            self.missing = missing
            self.at = at
        }
    }

    /// The merged result: the lines, plus what had to be assumed to order them.
    public struct Timeline: Sendable, Equatable {
        public var lines: [Line]
        /// The device whose clock everything was normalized onto.
        public var referenceDevice: String
        /// Human-readable statements about clock alignment — what was
        /// estimated, from which handshake, and what was left uncorrected.
        /// Written into the rendered timeline so no reader has to wonder.
        public var clockNotes: [String]
        /// Where events were dropped, in merged order. See ``Gap``.
        public var gaps: [Gap]

        public init(
            lines: [Line],
            referenceDevice: String,
            clockNotes: [String],
            gaps: [Gap] = []
        ) {
            self.lines = lines
            self.referenceDevice = referenceDevice
            self.clockNotes = clockNotes
            self.gaps = gaps
        }
    }

    /// Merge bundles into one ordered timeline. The reference clock is the
    /// sharer's when there is one — every offset estimates directly against
    /// it rather than through a third machine — otherwise the first bundle given.
    public static func merge(_ bundles: [DiagnosticsBundle]) -> Timeline {
        guard !bundles.isEmpty else {
            return Timeline(lines: [], referenceDevice: "", clockNotes: [])
        }

        // Identified by what the bundle CONTAINS (sending a HELLO_ACK), not
        // its header role — a process can be both sharer and viewer at once,
        // so the header role is only a default.
        let referenceIndex =
            bundles.firstIndex { bundle in
                bundle.events.contains { $0.name == DiagnosticEventName.helloAckSent.rawValue }
            } ?? 0
        let reference = bundles[referenceIndex]
        var notes: [String] = []

        var lines: [Line] = []
        var gaps: [Gap] = []
        for (index, bundle) in bundles.enumerated() {
            let offset: TimeInterval
            if index == referenceIndex {
                offset = 0
            } else if let estimate = estimateOffset(of: bundle, against: reference) {
                offset = estimate.seconds
                notes.append(
                    "\(bundle.header.device): clock offset \(formatted(estimate.seconds)) vs "
                        + "\(reference.header.device), from the SSRC \(estimate.ssrc) handshake "
                        + "(round trip \(formatted(estimate.roundTripSeconds))).")
            } else {
                offset = 0
                notes.append(
                    "\(bundle.header.device): no handshake pairs \(reference.header.device), so "
                        + "its timestamps are shown as recorded and may be skewed.")
            }

            // One offset per bundle, from one handshake, applied to every
            // session in it — disclosed, since a multi-session bundle's later
            // sessions are corrected by an earlier one's estimate, off by
            // whatever the clocks drifted in between.
            let sessions = Set(bundle.events.map(\.session))
            if sessions.count > 1, offset != 0 {
                notes.append(
                    "\(bundle.header.device): that offset was measured in one of "
                        + "\(sessions.count) sessions and applied to all of them; sessions far "
                        + "apart in time may have drifted since.")
            }

            // Each side replays from one wall-clock anchor (derived from the
            // handshake, see `anchor(for:)`) plus its own monotonic elapsed,
            // not each event's recorded wall clock — a mid-session NTP step
            // could otherwise invert two events on the same device.
            let anchor = Self.anchor(for: bundle)

            var previousSeq: UInt64?
            for event in bundle.events {
                var shifted = event
                if let anchor {
                    shifted.wallClock = anchor.addingTimeInterval(
                        Double(event.monotonicNs) / 1_000_000_000 + offset)
                } else {
                    shifted.wallClock = event.wallClock.addingTimeInterval(offset)
                }
                // Sequence numbers are dense, so any jump is an eviction — the
                // leading case (first event not at seq 1) is a whole
                // prologue lost to the retention cap.
                let expected = previousSeq.map { $0 &+ 1 } ?? 1
                if event.seq > expected {
                    gaps.append(
                        Gap(
                            device: bundle.header.device,
                            missing: event.seq &- expected,
                            at: shifted.wallClock))
                }
                previousSeq = event.seq
                lines.append(
                    Line(
                        device: bundle.header.device,
                        // The event's role, not the header's default (`.app`).
                        role: event.role,
                        event: shifted,
                        originalWallClock: event.wallClock,
                        appliedOffsetSeconds: offset))
            }
        }

        // Sort on the corrected clock, then break ties deterministically —
        // else two same-millisecond events on different devices could reorder between runs.
        lines.sort { lhs, rhs in
            if lhs.event.wallClock != rhs.event.wallClock {
                return lhs.event.wallClock < rhs.event.wallClock
            }
            if lhs.device != rhs.device { return lhs.device < rhs.device }
            return lhs.event.seq < rhs.event.seq
        }

        // Sorted the same way as `lines` so the renderer walks both in one pass.
        gaps.sort { lhs, rhs in
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            return lhs.device < rhs.device
        }

        return Timeline(
            lines: lines,
            referenceDevice: reference.header.device,
            clockNotes: notes,
            gaps: gaps)
    }

    /// A clock-offset estimate and the handshake it came from.
    public struct OffsetEstimate: Sendable, Equatable {
        /// Seconds to add to `subject`'s timestamps to reach the reference.
        public var seconds: TimeInterval
        /// Measured round trip, as a sanity check on the estimate — a large
        /// value means the offset is correspondingly uncertain.
        public var roundTripSeconds: TimeInterval
        /// The SSRC the two sides were paired on.
        public var ssrc: Int64
    }

    /// Estimate how far `subject`'s clock is from `reference`'s, using the
    /// handshake between them. Tries both ways round (subject-as-viewer,
    /// subject-as-sharer), since neither header decides which it was.
    /// Returns nil when the four timestamps aren't all present.
    public static func estimateOffset(
        of subject: DiagnosticsBundle,
        against reference: DiagnosticsBundle
    ) -> OffsetEstimate? {
        // Subject is the viewer: add the sharer's lead to the subject's clock.
        if let pair = handshake(client: subject, server: reference) {
            return OffsetEstimate(
                seconds: pair.serverLead,
                roundTripSeconds: pair.roundTrip,
                ssrc: pair.ssrc)
        }
        // Subject is the sharer: the reference is the viewer, so the sign
        // flips — the subject must move by the negation of its own lead.
        if let pair = handshake(client: reference, server: subject) {
            return OffsetEstimate(
                seconds: -pair.serverLead,
                roundTripSeconds: pair.roundTrip,
                ssrc: pair.ssrc)
        }
        return nil
    }

    private struct HandshakePair {
        /// How far the server's (sharer's) clock leads the client's (viewer's).
        var serverLead: TimeInterval
        var roundTrip: TimeInterval
        var ssrc: Int64
    }

    /// Find one completed handshake where `client` sent the HELLO and `server`
    /// answered it, and solve for the clock offset.
    private static func handshake(
        client: DiagnosticsBundle,
        server: DiagnosticsBundle
    ) -> HandshakePair? {
        // Pair on the SSRC the sharer assigned. First completed handshake,
        // not latest — closest to the prologue, least likely evicted.
        for ackReceived in client.events
        where ackReceived.name == DiagnosticEventName.helloAckReceived.rawValue {
            guard case .int(let ssrc)? = ackReceived.fields["ssrc"] else { continue }
            guard
                let ackSent = server.events.first(where: {
                    $0.name == DiagnosticEventName.helloAckSent.rawValue
                        && $0.fields["ssrc"] == .int(ssrc)
                })
            else { continue }

            // Last HELLO before the ack, not first — a viewer retries until
            // acked, and only the final retry produced this ack. The
            // sharer's HELLO must be THIS viewer's: several joiners at once
            // interleave `hello.received`, so match on the ack's own `addr`.
            //
            // Both "before" tests compare `seq`, not `wallClock` — sequence
            // is exact and monotonic within a bundle; the wall clock is the
            // thing that can step and reject a legitimate pair. Both are
            // also scoped to the ack's own session, so a multi-session
            // bundle can't pair across unrelated handshakes.
            let ackAddr = ackSent.fields["addr"]
            guard
                let helloSent = client.events.last(where: {
                    $0.name == DiagnosticEventName.helloSent.rawValue
                        && $0.session == ackReceived.session
                        && $0.seq <= ackReceived.seq
                }),
                let helloReceived = server.events.last(where: {
                    $0.name == DiagnosticEventName.helloReceived.rawValue
                        && $0.session == ackSent.session
                        && $0.seq <= ackSent.seq
                        // Older bundles predate the addr field; fall back rather than refusing to align.
                        && (ackAddr == nil || $0.fields["addr"] == nil
                            || $0.fields["addr"] == ackAddr)
                })
            else { continue }

            let t1 = helloSent.wallClock.timeIntervalSince1970
            let t2 = helloReceived.wallClock.timeIntervalSince1970
            let t3 = ackSent.wallClock.timeIntervalSince1970
            let t4 = ackReceived.wallClock.timeIntervalSince1970

            let serverLead = ((t2 - t1) + (t3 - t4)) / 2
            let roundTrip = (t4 - t1) - (t3 - t2)

            // A negative round trip means the pairing is wrong (two unrelated
            // sessions, a reused SSRC). Refusing beats a confidently wrong offset.
            guard roundTrip >= 0 else { continue }
            return HandshakePair(serverLead: serverLead, roundTrip: roundTrip, ssrc: ssrc)
        }
        return nil
    }

    /// The wall-clock time this bundle's monotonic zero corresponds to.
    /// Derived from the handshake event, not the session start — the offset
    /// already accounts for any clock step before the handshake, and
    /// anchoring earlier would reintroduce that discontinuity. `startedAt`
    /// is the fallback for a bundle with no completed handshake.
    static func anchor(for bundle: DiagnosticsBundle) -> Date? {
        let handshakeNames: Set<String> = [
            DiagnosticEventName.helloAckSent.rawValue,
            DiagnosticEventName.helloAckReceived.rawValue
        ]
        if let handshake = bundle.events.first(where: { handshakeNames.contains($0.name) }) {
            return handshake.wallClock.addingTimeInterval(
                -Double(handshake.monotonicNs) / 1_000_000_000)
        }
        return bundle.header.startedAt ?? bundle.events.first?.wallClock
    }

    private static func formatted(_ seconds: TimeInterval) -> String {
        let ms = seconds * 1000
        if abs(ms) < 1000 { return String(format: "%+.1f ms", ms) }
        return String(format: "%+.2f s", seconds)
    }
}
