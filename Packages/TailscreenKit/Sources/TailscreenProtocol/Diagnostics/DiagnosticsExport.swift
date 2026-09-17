import Foundation

/// Getting a bundle out of the app and into somebody else's hands.
///
/// Two outputs, on purpose:
///
///   * ``write(_:to:)`` writes the **`.jsonl` bundle** — the machine-readable
///     artifact, one side per file, meant to be sent.
///   * ``renderTimeline(_:)`` renders a **merged, readable timeline** across
///     however many bundles were collected. This is what somebody pastes into
///     a chat or an issue, and what an agent reads first.
///
/// The second is not a convenience. A bundle pair is two files of a few
/// thousand JSON lines each; the useful thing is the forty lines where the two
/// sides interleave around the moment it went wrong. Rendering that is the
/// difference between "here are the logs" and an answer.
public enum DiagnosticsExport {

    /// Filename for one side's bundle:
    /// `tailscreen-sharer-roberts-mac-20260917-100402.jsonl`.
    ///
    /// Role and device are in the name because these files arrive in pairs, in
    /// a chat thread, out of order, often renamed. A name that says which end
    /// it came from survives that; `diagnostics.jsonl` twice does not.
    public static func filename(
        role: DiagnosticRole,
        device: String,
        at date: Date = Date()
    ) -> String {
        "tailscreen-\(role.rawValue)-\(slug(device))-\(stamp(date)).jsonl"
    }

    /// A name that cannot collide with one already in `directory`.
    ///
    /// The stamp has one-second resolution, so two exports inside the same
    /// second produced the same path and the atomic write silently destroyed
    /// the first — which, for a feature whose whole job is preserving evidence,
    /// is the worst possible rounding error. A double-click on Export is enough
    /// to hit it.
    static func uniqueFilename(
        role: DiagnosticRole,
        device: String,
        at date: Date = Date(),
        existsAtPath: (String) -> Bool
    ) -> String {
        let base = "tailscreen-\(role.rawValue)-\(slug(device))-\(stamp(date))"
        if !existsAtPath("\(base).jsonl") { return "\(base).jsonl" }
        // Two is already unusual; ten in one second is somebody leaning on the
        // button, and a suffixed name still beats an overwrite.
        for suffix in 2...99 where !existsAtPath("\(base)-\(suffix).jsonl") {
            return "\(base)-\(suffix).jsonl"
        }
        return "\(base)-\(UUID().uuidString.prefix(8)).jsonl"
    }

    /// Write a bundle, creating intermediate directories.
    ///
    /// Atomic: the file is never observed half-written. Diagnostics are
    /// exported at exactly the moments things are going wrong — including, in
    /// the worst case, on the way out of a crash-adjacent teardown — and a
    /// truncated bundle that parses to a plausible-but-short session is worse
    /// than no bundle, because nothing about it looks wrong.
    @discardableResult
    public static func write(_ bundle: DiagnosticsBundle, to url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try bundle.jsonLinesData().write(to: url, options: .atomic)
        return url
    }

    /// Render a merged timeline as text.
    ///
    /// The shape is fixed-width columns, because the reader is scanning for a
    /// change in one of them — which device, which category, what happened —
    /// and ragged columns defeat that. Reading order:
    ///
    /// ```text
    ///   +1.841s  sharer-mac  handshake  hello.received       addr=100.64.0.3 caps=nack|rr|fec
    ///   +1.847s  viewer-pc   handshake  hello.ack.received   server_caps=nack|rr|fec ssrc=2
    /// ```
    ///
    /// Times are relative to the first event, which is what a reader actually
    /// wants ("three seconds in, the viewer was denied"); the absolute clock
    /// is in the header of each bundle for anyone who needs to line this up
    /// against something external.
    public static func renderTimeline(_ timeline: DiagnosticsMerge.Timeline) -> String {
        guard let first = timeline.lines.first else {
            return "No diagnostic events were recorded.\n"
        }

        var out = ""
        out += "Tailscreen diagnostics — merged timeline\n"
        out += "Reference clock: \(timeline.referenceDevice)\n"
        out += "Events: \(timeline.lines.count)\n"
        if !timeline.gaps.isEmpty {
            let dropped = timeline.gaps.reduce(UInt64(0)) { $0 &+ $1.missing }
            out += "Dropped: \(dropped) event(s) in \(timeline.gaps.count) gap(s)\n"
        }
        if !timeline.clockNotes.isEmpty {
            out += "\nClock alignment:\n"
            for note in timeline.clockNotes { out += "  - \(note)\n" }
        }
        out += "\n"

        // Column widths from the data, so a run of one device and a run of ten
        // both come out aligned rather than one being padded to the other's
        // worst case.
        let deviceWidth = timeline.lines.map(\.device.count).max() ?? 0
        let categoryWidth = timeline.lines.map(\.event.category.rawValue.count).max() ?? 0
        let nameWidth = min(timeline.lines.map(\.event.name.count).max() ?? 0, 36)
        let start = first.event.wallClock

        // Gap markers are interleaved rather than only summarized above,
        // because a total at the top does not tell a reader whether the hole is
        // anywhere near the two events they are drawing a conclusion between.
        // The list is sorted the same way `lines` is, so one index walks it.
        var nextGap = timeline.gaps.startIndex
        func emitGaps(upTo moment: Date) {
            while nextGap < timeline.gaps.endIndex, timeline.gaps[nextGap].at <= moment {
                let gap = timeline.gaps[nextGap]
                out += String(
                    format: "%@ %9.3fs  ", "!", gap.at.timeIntervalSince(start))
                out += "--- \(gap.device): \(gap.missing) event(s) dropped here ---\n"
                nextGap += 1
            }
        }

        // Where one device's session gives way to the next. A process shares
        // or views several times and a bundle retains the last few, so without
        // this the stream reads as one long run and a reader draws conclusions
        // between two events belonging to different shares. Per device, and
        // only on a CHANGE, so the ordinary single-session bundle says nothing.
        var lastSession: [String: UInt32] = [:]
        for line in timeline.lines {
            emitGaps(upTo: line.event.wallClock)
            if let previous = lastSession[line.device], previous != line.event.session {
                out += String(
                    format: "%@ %9.3fs  ", " ",
                    line.event.wallClock.timeIntervalSince(start))
                out += "=== \(line.device): session \(line.event.session) begins ===\n"
            }
            lastSession[line.device] = line.event.session
            let offset = line.event.wallClock.timeIntervalSince(start)
            let marker: String
            switch line.event.severity {
            case .info: marker = " "
            case .warning: marker = "!"
            case .error: marker = "*"
            }
            out += String(format: "%@ %9.3fs  ", marker, offset)
            out += line.device.padded(to: deviceWidth) + "  "
            out += line.event.category.rawValue.padded(to: categoryWidth) + "  "
            out += line.event.name.padded(to: nameWidth)
            if !line.event.fields.isEmpty {
                out += "  " + renderFields(line.event.fields)
            }
            out += "\n"
        }
        // A gap after the last retained event — everything since is missing.
        emitGaps(upTo: .distantFuture)
        return out
    }

    /// Fields as `key=value`, sorted by key.
    ///
    /// Sorted so the same event always renders its fields in the same order:
    /// a reader comparing two occurrences is looking for the one value that
    /// differs, and dictionary order would make every pair look different.
    static func renderFields(_ fields: [String: DiagnosticValue]) -> String {
        fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(render($0.value))" }
            .joined(separator: " ")
    }

    private static func render(_ value: DiagnosticValue) -> String {
        switch value {
        case .string(let text):
            // Escaped, then quoted when it would otherwise be ambiguous.
            //
            // The escaping is not cosmetic: this timeline is one event per
            // line, and a captured log message or error description containing
            // a newline would SPLIT one event across several lines — silently
            // turning a readable trace into one that appears to contain events
            // nothing recorded. A quote or backslash does the smaller version
            // of the same damage, ending a value early.
            let escaped = escape(text)
            let ambiguous =
                escaped.contains(" ") || escaped.contains("=") || escaped != text
            return ambiguous ? "\"\(escaped)\"" : escaped
        case .int(let number): return String(number)
        case .double(let number): return String(format: "%g", number)
        case .bool(let flag): return flag ? "true" : "false"
        }
    }

    /// Backslash-escape the characters that would break one-event-per-line.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(character)
            }
        }
        return out
    }

    /// `20260917-100402`, UTC. Sorts lexicographically, which is the point:
    /// bundles from one session land next to each other in any file listing.
    static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Reduce a device name to something safe in a filename on all three
    /// platforms, without mangling the ordinary case.
    ///
    /// Device names are user-chosen and arrive with spaces, apostrophes and
    /// emoji in them ("Robert's MacBook Pro"). Windows additionally rejects
    /// `<>:"/\|?*`, so the conservative rule — keep ASCII alphanumerics, fold
    /// everything else to a single dash — is the one that works everywhere.
    ///
    /// Apostrophes are the one exception, **dropped rather than folded**.
    /// They are extremely common in device names, because that is what both
    /// macOS and Windows generate by default from an account name, and folding
    /// gives `robert-s-macbook-pro` where dropping gives `roberts-macbook-pro`.
    /// A filename is something a person reads in a chat attachment before
    /// deciding whether to open it, so the difference is worth one branch.
    static func slug(_ name: String) -> String {
        var out = ""
        var lastWasDash = false
        for character in name.lowercased() {
            if character.isLetter && character.isASCII || character.isNumber && character.isASCII {
                out.append(character)
                lastWasDash = false
            } else if character == "'" || character == "\u{2019}" {
                // Both the typewriter apostrophe and the typographic one macOS
                // substitutes automatically.
                continue
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        // Trimmed, capped, then trimmed AGAIN: capping after the first trim can
        // hand back a trailing dash (a 40-character name whose 41st character
        // was a space), which is the very thing the first trim exists to
        // prevent.
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let capped = String(trimmed.prefix(40))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // A name that was entirely non-ASCII would slug to nothing and produce
        // `tailscreen-viewer--20260917-100402`, which reads like a bug.
        return capped.isEmpty ? "device" : capped
    }
}

extension String {
    /// Right-pad to `width`. Left alone when already at or over it — this is
    /// for column alignment, not truncation, and clipping an event name would
    /// hide exactly the tail that distinguishes `hello.ack.sent` from
    /// `hello.ack.received`.
    fileprivate func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
