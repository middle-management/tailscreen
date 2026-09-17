import Foundation

/// Interleaving two or more sides of one session into a single ordered story.
///
/// This is the payoff for recording at all. One side's bundle answers "what
/// did my machine do"; the pair answers "what happened", which is the question
/// anybody actually has. A viewer that waited thirty seconds and gave up and a
/// sharer that never saw a HELLO are the same bundle pair as a viewer that
/// waited thirty seconds and a sharer that saw the HELLO and parked it on an
/// approval prompt nobody was looking at — and those are completely different
/// bugs. Only the interleaving distinguishes them.
///
/// ## The clock problem, and why the handshake solves it
///
/// Two machines' wall clocks disagree, by milliseconds if they are both
/// healthy and by minutes if one is not. Sorting two bundles on raw timestamps
/// therefore produces, at best, a plausible-looking lie: an acknowledgement
/// before the message it acknowledges, a viewer connecting before the share
/// started. A reader who cannot see the skew will read causality out of the
/// order, because that is what an ordered list is for.
///
/// The fix is already on the wire. A handshake is exactly the four-timestamp
/// exchange NTP uses to estimate offset:
///
/// ```text
///   viewer  ──HELLO────────▶  t1 sent (viewer clock)   t2 received (sharer clock)
///   sharer  ◀─HELLO_ACK────   t4 received (viewer)     t3 sent (sharer clock)
/// ```
///
/// with `offset = ((t2 - t1) + (t3 - t4)) / 2` — the amount the sharer's clock
/// leads the viewer's, with the one-way delay cancelling out under the usual
/// assumption that it is roughly symmetric. The four events are recorded
/// anyway, so the correction costs nothing to collect, and the two sides are
/// paired on the **SSRC the sharer assigns in the HELLO_ACK** — a value both
/// ends already know and neither had to invent.
///
/// The estimate is reported, never silently applied: ``Timeline/clockNotes``
/// says what was inferred and from what. An offset a reader cannot see is
/// exactly as misleading as a skew they cannot see.
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

    /// A hole in one device's stream, where the recorder evicted events.
    ///
    /// The whole point of the drop counter is that a reader must not read the
    /// retained prologue and the recent ring as ADJACENT and infer causality
    /// across however long is missing — and until this existed the rendered
    /// timeline printed them adjacent with nothing between, which is exactly
    /// that failure. The JSONL header carried the count all along; nothing
    /// carried it into the thing people actually read.
    ///
    /// Located from a discontinuity in `seq`, not from the header's total:
    /// sequence numbers are dense by construction, so a jump says not just how
    /// many events are missing but WHERE, which is the part that lets a reader
    /// know whether the hole is anywhere near what they are looking at.
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

    /// Merge bundles into one ordered timeline.
    ///
    /// The reference clock is the **sharer's** when there is one, otherwise the
    /// first bundle given. The sharer is the better choice because it is the
    /// one side every other side talked to, so every offset is estimated
    /// directly against it rather than through a third machine.
    public static func merge(_ bundles: [DiagnosticsBundle]) -> Timeline {
        guard !bundles.isEmpty else {
            return Timeline(lines: [], referenceDevice: "", clockNotes: [])
        }

        // The sharer is the better reference because it is the one side every
        // other side talked to, so every offset is estimated directly against
        // it rather than through a third machine. Identified by what the
        // bundle CONTAINS rather than by its header role: one process can be
        // both sharer and viewer at once (a Mac sharing to one person while
        // watching another), so the header's role is a default, not a fact
        // about the session. Sending a HELLO_ACK is a fact.
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

            // Each side is replayed from ONE wall-clock anchor plus its own
            // monotonic elapsed, not from each event's recorded wall clock.
            // The anchor is derived from the HANDSHAKE, not from the session
            // start — see `anchor(for:)`.
            //
            // This is what `monotonicNs` was recorded for, and until now the
            // merge did not use it. A wall clock can step mid-session — NTP
            // correcting a drifting machine is routine, and a share is exactly
            // long enough for it — which would place a later event before an
            // earlier one on the SAME device, inventing a causal inversion
            // inside one machine's own story. The monotonic clock cannot do
            // that. The anchor is the first event's wall clock, so the timeline
            // still sits at the real time of day, and the cross-device offset
            // is applied on top exactly as before.
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
                // Sequence numbers are dense, so any jump is an eviction. The
                // leading case (`previousSeq == nil` and the first event is not
                // seq 1) is a whole session prologue released under the
                // retention cap — a hole with no event before it to hang off,
                // and the one a reader is least likely to suspect.
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
                        // The EVENT's role, not the bundle header's. The header
                        // carries the recorder's *default*, which in production
                        // is `.app` precisely because one process can share and
                        // view at once — so taking it here labelled every line
                        // `.app` and threw away the per-event role the rest of
                        // this type is built on.
                        role: event.role,
                        event: shifted,
                        originalWallClock: event.wallClock,
                        appliedOffsetSeconds: offset))
            }
        }

        // Sort on the corrected clock, then break ties deterministically. The
        // tie-break matters more than it looks: two events in the same
        // millisecond on two devices would otherwise order differently between
        // runs, and a timeline that reorders itself is one nobody can cite.
        lines.sort { lhs, rhs in
            if lhs.event.wallClock != rhs.event.wallClock {
                return lhs.event.wallClock < rhs.event.wallClock
            }
            if lhs.device != rhs.device { return lhs.device < rhs.device }
            return lhs.event.seq < rhs.event.seq
        }

        // Sorted the same way the lines are, so the renderer can walk both in
        // one pass and a marker always lands immediately before the event it
        // precedes.
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
    /// handshake between them.
    ///
    /// Tries the pairing both ways round — subject-as-viewer and
    /// subject-as-sharer — because neither bundle's header decides which it
    /// was. A process can be both at once, and what matters is only which end
    /// of one particular handshake each bundle holds.
    ///
    /// Returns nil when the four timestamps are not all present: a viewer that
    /// never completed a handshake with this sharer, a bundle whose prologue
    /// was cleared, two bundles from unrelated sessions.
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
        // Pair on the SSRC the sharer assigned. Taking the FIRST completed
        // handshake rather than the latest: it is the one closest to the
        // prologue, so it is the one least likely to have been evicted, and a
        // reconnect later in the session would estimate the same offset anyway.
        for ackReceived in client.events
        where ackReceived.name == DiagnosticEventName.helloAckReceived.rawValue {
            guard case .int(let ssrc)? = ackReceived.fields["ssrc"] else { continue }
            guard
                let ackSent = server.events.first(where: {
                    $0.name == DiagnosticEventName.helloAckSent.rawValue
                        && $0.fields["ssrc"] == .int(ssrc)
                })
            else { continue }

            // The client's HELLO is the last one it sent before the ack came
            // back; the server's is the last it saw before it answered. "Last
            // before" rather than "first" because a viewer retries its HELLO
            // until acked, and it is the final retry that actually produced
            // this ack — pairing against the first would fold the whole retry
            // period into the offset.
            // The sharer's HELLO must be THIS viewer's. A share with several
            // people joining at once has many `hello.received` interleaved, and
            // taking the latest before the ack would happily pick another
            // viewer's retry as `t2` — yielding an offset that looks entirely
            // plausible and is wrong. The ack carries the addr it answered, so
            // the pairing is available; it just was not being used.
            //
            // Both "before" tests compare `seq`, not `wallClock`. They are
            // WITHIN one bundle, where sequence is exact, local and monotonic
            // by construction — while the wall clock is the very thing that can
            // step, and a backward step between the HELLO and the ACK made the
            // legitimate HELLO compare LATER than the ack, so the pair was
            // rejected and the alignment this function exists for silently did
            // not happen. The four timestamps below are still wall clocks,
            // because the offset is a statement about wall clocks; it is only
            // the SELECTION that must not be.
            let ackAddr = ackSent.fields["addr"]
            guard
                let helloSent = client.events.last(where: {
                    $0.name == DiagnosticEventName.helloSent.rawValue
                        && $0.seq <= ackReceived.seq
                }),
                let helloReceived = server.events.last(where: {
                    $0.name == DiagnosticEventName.helloReceived.rawValue
                        && $0.seq <= ackSent.seq
                        // Older bundles predate the addr field on one side or
                        // the other; falling back to time-only there keeps them
                        // readable rather than refusing to align them at all.
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

            // A negative round trip is impossible and means the pairing is
            // wrong (two unrelated sessions, a reused SSRC across a restart).
            // Refusing is right: a confidently wrong offset is worse than none.
            guard roundTrip >= 0 else { continue }
            return HandshakePair(serverLead: serverLead, roundTrip: roundTrip, ssrc: ssrc)
        }
        return nil
    }

    /// The wall-clock time this bundle's monotonic zero corresponds to.
    ///
    /// Derived from the **handshake** event where there is one, not from the
    /// session start, and the difference matters whenever a clock steps
    /// between the two. The offset is estimated from handshake timestamps, so
    /// it already contains any step that happened before them; anchoring at
    /// `startedAt` — a reading taken *before* the step — then replays the whole
    /// side from a pre-step origin while correcting it by a post-step offset,
    /// leaving the timeline shifted by exactly that discontinuity.
    ///
    /// Anchoring on the handshake makes the two consistent: the same event
    /// that produced the offset also fixes the origin. `startedAt` remains the
    /// fallback for a bundle that never completed one, where there is nothing
    /// better to use.
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
