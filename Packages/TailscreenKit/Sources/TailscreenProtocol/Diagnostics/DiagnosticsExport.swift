import Foundation

/// Getting a bundle out of the app and into somebody else's hands.
///
/// Two outputs: ``write(_:to:)`` writes the machine-readable `.jsonl` bundle,
/// one side per file; ``renderTimeline(_:)`` renders a merged, readable
/// timeline across however many bundles were collected — the forty lines
/// where two sides interleave around the moment it went wrong, not two files
/// of a few thousand lines each.
public enum DiagnosticsExport {

    /// Filename for one side's bundle:
    /// `tailscreen-sharer-roberts-mac-20260917-100402.jsonl`. Role and device
    /// are in the name since these files arrive in pairs, renamed and out of
    /// order — `diagnostics.jsonl` twice would not survive that.
    public static func filename(
        role: DiagnosticRole,
        device: String,
        at date: Date = Date()
    ) -> String {
        "tailscreen-\(role.rawValue)-\(slug(device))-\(stamp(date)).jsonl"
    }

    /// A name that cannot collide with one already in `directory`. The
    /// stamp's one-second resolution means two exports in the same second
    /// (a double-click on Export is enough) would otherwise silently
    /// overwrite the first.
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

    /// Filename for a MERGED timeline: `tailscreen-merged-20260918-100402.txt`.
    /// `.txt`, not `.jsonl`: rendered prose, not a bundle, feeding it back
    /// into the merge would fail. No role or device — it has two of each,
    /// named inside on every line.
    public static func mergedFilename(at date: Date = Date()) -> String {
        "tailscreen-merged-\(stamp(date)).txt"
    }

    /// A merged-timeline name that cannot collide with one already in
    /// `directory` — same one-second-resolution problem as
    /// ``uniqueFilename(role:device:at:existsAtPath:)``.
    static func uniqueMergedFilename(
        at date: Date = Date(),
        existsAtPath: (String) -> Bool
    ) -> String {
        let base = "tailscreen-merged-\(stamp(date))"
        if !existsAtPath("\(base).txt") { return "\(base).txt" }
        for suffix in 2...99 where !existsAtPath("\(base)-\(suffix).txt") {
            return "\(base)-\(suffix).txt"
        }
        return "\(base)-\(UUID().uuidString.prefix(8)).txt"
    }

    /// Write a bundle, creating intermediate directories. Atomic: never
    /// observed half-written — a truncated bundle that parses to a
    /// plausible-but-short session is worse than no bundle at all.
    @discardableResult
    public static func write(_ bundle: DiagnosticsBundle, to url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try bundle.jsonLinesData().write(to: url, options: .atomic)
        return url
    }

    /// Render a merged timeline as text, fixed-width columns so a reader can
    /// scan for a change in device/category/name:
    ///
    /// ```text
    ///   +1.841s  sharer-mac  handshake  hello.received       addr=100.64.0.3 caps=nack|rr|fec
    ///   +1.847s  viewer-pc   handshake  hello.ack.received   server_caps=nack|rr|fec ssrc=2
    /// ```
    ///
    /// Times are relative to the first event ("three seconds in, the viewer
    /// was denied"); absolute clock is in each bundle's header.
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

        // Column widths from the data, so columns align regardless of device count.
        let deviceWidth = timeline.lines.map(\.device.count).max() ?? 0
        let categoryWidth = timeline.lines.map(\.event.category.rawValue.count).max() ?? 0
        let nameWidth = min(timeline.lines.map(\.event.name.count).max() ?? 0, 36)
        let start = first.event.wallClock

        // Gap markers interleaved, not just summarized at top, so a reader
        // sees whether a hole sits near the events they're comparing.
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

        // Where one device's session gives way to the next, per device, only
        // on change, so an ordinary single-session bundle says nothing.
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

    /// Fields as `key=value`, sorted by key, so the same event always
    /// renders in the same order for easy comparison.
    static func renderFields(_ fields: [String: DiagnosticValue]) -> String {
        fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(render($0.value))" }
            .joined(separator: " ")
    }

    private static func render(_ value: DiagnosticValue) -> String {
        switch value {
        case .string(let text):
            // Escaped, then quoted if ambiguous — an unescaped newline in a
            // captured message would split one event across several lines.
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
    /// platforms: keep ASCII alphanumerics, fold everything else to a single
    /// dash (Windows rejects `<>:"/\|?*`). Apostrophes are dropped rather
    /// than folded — common in device names, and dropping reads better
    /// (`roberts-macbook-pro` vs. `robert-s-macbook-pro`).
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
        // Trimmed, capped, then trimmed again — capping alone can reintroduce a trailing dash.
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let capped = String(trimmed.prefix(40))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // An entirely non-ASCII name would otherwise slug to nothing.
        return capped.isEmpty ? "device" : capped
    }
}

extension String {
    /// Right-pad to `width`, unless already at or over it — for column
    /// alignment, not truncation.
    fileprivate func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
