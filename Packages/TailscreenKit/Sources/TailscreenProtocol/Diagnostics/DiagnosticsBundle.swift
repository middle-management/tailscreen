import Foundation

/// One side's recording, packaged for somebody else to read.
///
/// ## Why JSON Lines
///
/// A bundle is one header line followed by one line per event. Not a JSON
/// document, not a zip, not a proprietary format — because of who reads it:
///
///   * **It greps.** `grep hello. bundle.jsonl` works, and so does
///     `jq -c 'select(.severity=="error")'`. A single top-level JSON array
///     makes both need a parser first.
///   * **It streams and truncates.** A bundle cut short by a failed upload is
///     still readable up to the cut; a truncated JSON document is not
///     readable at all.
///   * **It diffs and it merges.** Interleaving two sides is a sort on lines.
///   * **It is legible to a person over somebody's shoulder**, which a binary
///     format is not, and that matters for a file you are asking a user to
///     look at before they send it to you.
///
/// The header comes first so a reader knows the build, the platform and the
/// role before it reads an event, and so `head -1` is a complete answer to
/// "what am I looking at".
public struct DiagnosticsBundle: Sendable, Equatable {

    /// What the reader needs to know before the first event.
    public struct Header: Sendable, Equatable, Codable {

        /// Format version. Bumped when a reader would get the wrong answer
        /// from an old parse — not when an event name is added, which is
        /// routine and backward compatible by construction.
        public static let currentSchema = 1

        public var schema: Int
        /// Which half of the session — `sharer`, `viewer` or `app`.
        public var role: DiagnosticRole
        /// The name a reader identifies this side by.
        public var device: String
        public var platform: String
        /// Marketing version, e.g. `0.10.0-rc.2`, or `dev`.
        public var appVersion: String
        /// Short commit SHA, as `BuildInfo.commit` stamps it.
        public var commit: String
        /// `debug` or `release`.
        public var configuration: String
        public var architecture: String
        public var channel: ReleaseChannel
        /// When the first event was recorded.
        public var startedAt: Date?
        /// When this bundle was written.
        public var exportedAt: Date
        public var eventCount: Int
        /// Events lost from the middle of the stream. **Non-zero means the
        /// events before and after the gap are not adjacent in time** — see
        /// ``DiagnosticsRecorder``'s prologue/ring split.
        public var droppedCount: UInt64
        /// Whether recording was actually on. An empty bundle means something
        /// very different when the answer here is `false`.
        public var wasRecording: Bool

        /// Plain-language statement of what is in the file, written into the
        /// bundle itself.
        ///
        /// Not decoration. A user is being asked to send this to somebody, and
        /// the honest version of that request names what they are sending. It
        /// lives in the file rather than only in the UI that produced it
        /// because the file is what gets forwarded, and the second recipient
        /// never saw the dialog.
        public var contentNotice: String

        /// The disclosure every bundle carries. States both halves of
        /// ``DiagnosticsRedaction``'s rule — what was removed, and what was
        /// deliberately kept — because a notice that only mentions the
        /// redaction implies the rest is anonymous.
        public static let standardContentNotice = """
            This file records what this device did during a Tailscreen session: \
            connections, handshakes, actions taken, and errors. It names your \
            device and the devices it talked to, including their tailnet \
            addresses, and the microphones and speakers attached to this \
            machine. It does NOT contain share links, auth keys, sign-in URLs, \
            your Tailscale account name, screen contents, audio, or \
            keystrokes. Share it with someone you would be comfortable telling \
            which machines you connected to.
            """

        public init(
            schema: Int = Header.currentSchema,
            role: DiagnosticRole,
            device: String,
            platform: String,
            appVersion: String,
            commit: String,
            configuration: String,
            architecture: String,
            channel: ReleaseChannel,
            startedAt: Date?,
            exportedAt: Date,
            eventCount: Int,
            droppedCount: UInt64,
            wasRecording: Bool,
            contentNotice: String = Header.standardContentNotice
        ) {
            self.schema = schema
            self.role = role
            self.device = device
            self.platform = platform
            self.appVersion = appVersion
            self.commit = commit
            self.configuration = configuration
            self.architecture = architecture
            self.channel = channel
            self.startedAt = startedAt
            self.exportedAt = exportedAt
            self.eventCount = eventCount
            self.droppedCount = droppedCount
            self.wasRecording = wasRecording
            self.contentNotice = contentNotice
        }
    }

    public var header: Header
    public var events: [DiagnosticEvent]

    public init(header: Header, events: [DiagnosticEvent]) {
        self.header = header
        self.events = events
    }

    /// Package a snapshot with the build facts the host knows and the portable
    /// tier does not.
    ///
    /// `BuildInfo` deliberately stays a per-app file (it is stamped by each
    /// platform's own workflow), so those values arrive in a
    /// ``DiagnosticsEnvironment`` rather than being read here.
    public static func make(
        from snapshot: DiagnosticsSnapshot,
        environment: DiagnosticsEnvironment,
        exportedAt: Date = Date()
    ) -> DiagnosticsBundle {
        let header = Header(
            role: snapshot.role,
            // The recorder's label, not the environment's: the snapshot is what
            // actually recorded these events, and if the two ever disagree the
            // events are the ones telling the truth.
            device: snapshot.deviceLabel,
            platform: environment.platform,
            appVersion: environment.appVersion,
            commit: environment.commit,
            configuration: environment.configuration,
            architecture: environment.architecture,
            channel: environment.channel,
            startedAt: snapshot.startedAt,
            exportedAt: exportedAt,
            eventCount: snapshot.events.count,
            droppedCount: snapshot.droppedCount,
            wasRecording: snapshot.wasRecording)
        return DiagnosticsBundle(header: header, events: snapshot.events)
    }

    // MARK: - Serialization

    /// The whole bundle as JSON Lines text, header first.
    ///
    /// Built as `Data` by ``jsonLinesData()`` and converted once at the end.
    /// The bytes are what gets written to disk, so producing them directly and
    /// converting only for callers that want text is both the cheaper order
    /// and the one that keeps a single definition of the format.
    public func jsonLines() throws -> String {
        guard let text = String(bytes: try jsonLinesData(), encoding: .utf8) else {
            // JSONEncoder emits valid UTF-8, so this is unreachable in
            // practice — but a failable conversion beats one that silently
            // substitutes U+FFFD into a file somebody is going to read.
            throw DiagnosticsBundleError.encodingFailed
        }
        return text
    }

    /// The whole bundle as JSON Lines bytes, header first. What is written to
    /// disk.
    public func jsonLinesData() throws -> Data {
        let encoder = JSONEncoder()
        // Sorted keys so two exports of the same events are byte-identical and
        // a bundle diffs against itself usefully. ISO-8601 with fractional
        // seconds because merging two machines on whole seconds would reorder
        // a handshake that takes milliseconds.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(DiagnosticsBundle.format(date))
        }

        // Trailing newline after every line, including the last: the file is a
        // stream of lines, and a reader that appends to it must not land on the
        // same line as the last event.
        let newline = Data([0x0A])
        var out = Data()
        out.append(try encoder.encode(HeaderLine(header: header)))
        out.append(newline)
        for event in events {
            out.append(try encoder.encode(event))
            out.append(newline)
        }
        return out
    }

    /// Parse a bundle back.
    ///
    /// **Tolerant by design.** Unknown event names, unknown categories, blank
    /// lines and lines a newer build wrote with fields this one has never
    /// heard of all survive — the same instinct as the wire's tolerant
    /// `decodeHelloAckCaps`. A reader that refuses a bundle from a slightly
    /// newer build is a reader that fails exactly when it is needed, since the
    /// person with the problem is by definition the one running the newer
    /// build.
    public static func parse(jsonLines text: String) throws -> DiagnosticsBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = DiagnosticsBundle.parseDate(text) else {
                throw DiagnosticsBundleError.malformedDate(text)
            }
            return date
        }

        var header: Header?
        var events: [DiagnosticEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let data = Data(trimmed.utf8)
            if header == nil, let parsed = try? decoder.decode(HeaderLine.self, from: data) {
                header = parsed.header
                continue
            }
            // A line that will not parse is skipped rather than fatal: one
            // corrupt line in the middle must not cost the other four thousand.
            if let event = try? decoder.decode(DiagnosticEvent.self, from: data) {
                events.append(event)
            }
        }
        guard let header else { throw DiagnosticsBundleError.missingHeader }
        // The ONE thing this otherwise-tolerant parser refuses.
        //
        // Unknown event names, unknown categories and corrupt lines are all
        // skipped on purpose — a reader that rejects a bundle from a newer
        // build fails exactly when it is needed, since the person with the
        // problem is the one running the newer build. A schema bump is the
        // opposite case by definition: `currentSchema` changes only when an
        // older reader would produce the WRONG answer, so guessing produces a
        // confidently incorrect timeline, which this whole feature treats as
        // worse than no timeline. Older schemas stay readable.
        guard header.schema <= Header.currentSchema else {
            throw DiagnosticsBundleError.unsupportedSchema(header.schema)
        }
        return DiagnosticsBundle(header: header, events: events)
    }

    /// Wrapper that tags the header line so `parse` can tell it from an event
    /// without positional trust — a concatenated pair of bundles still reads.
    struct HeaderLine: Codable {
        /// Always `"tailscreen.diagnostics.header"`.
        var kind: String
        var header: Header

        init(header: Header) {
            self.kind = "tailscreen.diagnostics.header"
            self.header = header
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            guard kind == "tailscreen.diagnostics.header" else {
                throw DiagnosticsBundleError.missingHeader
            }
            self.kind = kind
            self.header = try container.decode(Header.self, forKey: .header)
        }
    }

    /// The timestamp formatters, behind a lock.
    ///
    /// `ISO8601DateFormatter` is a mutable class and therefore not `Sendable`,
    /// so a plain `static let` does not compile under this package's strict
    /// concurrency — correctly, because two threads exporting at once would
    /// share its internal state. `NSLock` rather than `Synchronization.Mutex`
    /// for the reason spelled out on ``Guarded`` (TSan cannot see through
    /// `Mutex`, so it cannot check a type behind one) — and bare rather than a
    /// ``Guarded`` because this guards two separate statics, not one value.
    /// The contention is nothing either way, since formatting happens on
    /// export and parse, not on the recording path.
    ///
    /// Two formatters because the fractional-seconds option is not tolerant —
    /// a formatter configured `.withFractionalSeconds` returns nil for a
    /// stamp without them, so reading needs both and tries them in order.
    private static let formattersLock = NSLock()
    /// `nonisolated(unsafe)` because `formattersLock` is what makes it safe,
    /// and the compiler cannot see that. Same bargain as the `@unchecked
    /// Sendable` conformances elsewhere in this repo: we own the invariant,
    /// the compiler is not checking it — and here the invariant is one lock
    /// around two accessors, both in this file.
    nonisolated(unsafe) private static let formatters = Formatters()

    private final class Formatters {
        let fractional: ISO8601DateFormatter
        let plain: ISO8601DateFormatter

        init() {
            fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
        }
    }

    /// Render a timestamp in the bundle's one format: RFC 3339 UTC with
    /// milliseconds, e.g. `2026-09-17T10:04:02.117Z`.
    static func format(_ date: Date) -> String {
        formattersLock.lock()
        defer { formattersLock.unlock() }
        return formatters.fractional.string(from: date)
    }

    static func parseDate(_ text: String) -> Date? {
        formattersLock.lock()
        defer { formattersLock.unlock() }
        // Tolerate a stamp without fractional seconds — hand-edited bundles
        // and other producers exist, and losing a whole file over a missing
        // `.123` would be absurd.
        return formatters.fractional.date(from: text) ?? formatters.plain.date(from: text)
    }
}

public enum DiagnosticsBundleError: Error, Equatable {
    case missingHeader
    case malformedDate(String)
    /// The bundle declares a schema this build cannot read. See ``parse``.
    case unsupportedSchema(Int)
    /// The encoded bundle was not valid UTF-8. Unreachable with `JSONEncoder`,
    /// carried so the conversion can stay failable rather than lossy.
    case encodingFailed
}
