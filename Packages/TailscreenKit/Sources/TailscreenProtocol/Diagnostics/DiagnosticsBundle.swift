import Foundation

/// One side's recording, packaged for somebody else to read.
///
/// JSON Lines, not a JSON document or a zip: it greps (`jq -c 'select(...)'`
/// works line by line), streams and truncates safely, diffs and merges as a
/// sort on lines, and is legible over somebody's shoulder. The header comes
/// first so `head -1` answers "what am I looking at".
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
        /// bundle itself — not decoration, since the file gets forwarded and
        /// a second recipient never saw the export dialog.
        public var contentNotice: String

        /// The disclosure every bundle carries: both halves of
        /// ``DiagnosticsRedaction``'s rule, what was removed and what was
        /// deliberately kept.
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

    /// Package a snapshot with the build facts the host knows and the
    /// portable tier does not — `BuildInfo` stays per-app, so those values
    /// arrive via ``DiagnosticsEnvironment``.
    public static func make(
        from snapshot: DiagnosticsSnapshot,
        environment: DiagnosticsEnvironment,
        exportedAt: Date = Date()
    ) -> DiagnosticsBundle {
        let header = Header(
            role: snapshot.role,
            // The recorder's label, not the environment's: the snapshot is what actually recorded these events.
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

    /// The whole bundle as JSON Lines text, header first. Built as `Data` by
    /// ``jsonLinesData()`` and converted once, since the bytes are what's
    /// written to disk.
    public func jsonLines() throws -> String {
        guard let text = String(bytes: try jsonLinesData(), encoding: .utf8) else {
            // Unreachable in practice (JSONEncoder emits valid UTF-8), but a
            // failable conversion beats silently substituting U+FFFD.
            throw DiagnosticsBundleError.encodingFailed
        }
        return text
    }

    /// The whole bundle as JSON Lines bytes, header first. What is written to
    /// disk.
    public func jsonLinesData() throws -> Data {
        let encoder = JSONEncoder()
        // Sorted keys so two exports of the same events are byte-identical.
        // ISO-8601 with fractional seconds, since whole-second merging would
        // reorder a millisecond handshake.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(DiagnosticsBundle.format(date))
        }

        // Trailing newline after every line, including the last, so an appending reader lands on a new line.
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

    /// Parse a bundle back. Tolerant by design: unknown event names,
    /// categories, blank lines, and fields from a newer build all survive —
    /// a reader that refuses a slightly newer bundle fails exactly when it's needed.
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
            // A line that won't parse is skipped, not fatal — one corrupt
            // line must not cost the other four thousand.
            if let event = try? decoder.decode(DiagnosticEvent.self, from: data) {
                events.append(event)
            }
        }
        guard let header else { throw DiagnosticsBundleError.missingHeader }
        // The one thing this otherwise-tolerant parser refuses: `currentSchema`
        // only bumps when an older reader would produce the wrong answer, so
        // guessing here is worse than refusing. Older schemas stay readable.
        guard header.schema <= Header.currentSchema else {
            throw DiagnosticsBundleError.unsupportedSchema(header.schema)
        }
        return DiagnosticsBundle(header: header, events: events)
    }

    /// Tags the header line so `parse` can tell it from an event without
    /// positional trust — a concatenated pair of bundles still reads.
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

    /// The timestamp formatters, behind a lock. `ISO8601DateFormatter` is a
    /// mutable class, not `Sendable`, so two threads exporting at once would
    /// share its state without one. `NSLock`, not `Synchronization.Mutex`
    /// (see ``Guarded``'s TSan note) — bare, not `Guarded`, since this guards
    /// two statics, not one value.
    ///
    /// Two formatters: `.withFractionalSeconds` returns nil for a stamp
    /// without them, so reading tries both in order.
    private static let formattersLock = NSLock()
    /// `nonisolated(unsafe)` because `formattersLock` is what makes it safe,
    /// which the compiler can't see — same bargain as `@unchecked Sendable` elsewhere.
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
        // Tolerate a stamp without fractional seconds (hand-edited bundles, other producers).
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
