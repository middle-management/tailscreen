import Foundation

/// The Windows half of a sharer notice: the toast XML, the activation string a
/// button press comes back as, and the tag a notice is later withdrawn by.
///
/// This is `WinNotifyKit`'s equivalent of the `actions` array GNotifyKit hands
/// to `Notify` — except that on Windows the whole notification is one XML
/// document handed to `AppNotification`, so *composing that document correctly*
/// is the delivery-shaped decision, and it is pure. It lives here, beside
/// `WindowsHotkeyMapping` and `WindowsPointerMapping`, for the same reason
/// those do: Linux CI can test it, and there is no Windows runner in the loop.
///
/// What it deliberately does **not** know: the words. Those are
/// `SharerNoticeText`'s, already rendered by the time they arrive here.
///
/// **The three ways a toast quietly does nothing.** None of them produce an
/// error, which is why each one is pinned by a test:
///
/// 1. **An unescaped `&` in a peer's name.** The payload is parsed as XML by
///    the platform, so a hostname carrying `&` or `<` makes `CreateInstance`
///    fail and nothing is posted at all — for that peer only, which is the
///    worst shape a bug like this can have.
/// 2. **A tag longer than 64 characters.** `AppNotification.Tag` is capped, and
///    an over-long tag is rejected rather than truncated — so the notice is
///    never posted, and the withdraw that was supposed to match it never
///    matches anything.
/// 3. **`scenario="urgent"` on Windows 10.** The attribute is a Windows 11
///    addition; an unrecognized scenario value is a schema violation, not a
///    politely ignored hint. `reminder` is the universally-understood way to
///    say "stay on screen until answered", so that is what an older desktop
///    gets — the host asks the backend which it has.
public enum WindowsToastPayload {
    /// One button on a toast.
    public struct Button: Equatable, Sendable {
        /// Comes back verbatim inside the activation string. Never shown.
        public let key: String
        /// The visible label. Already localized by the caller.
        public let label: String

        public init(key: String, label: String) {
            self.key = key
            self.label = label
        }
    }

    /// The `scenario` attribute, which is how a toast asks to outlive the few
    /// seconds a banner normally gets.
    ///
    /// Windows spends this the way macOS spends `.timeSensitive` and
    /// freedesktop spends `critical`: per *app*, revocable by the user. So the
    /// mapping below is deliberately stingy — see `scenario(blocksSomeone:…)`.
    public enum Scenario: String, Sendable, CaseIterable {
        /// No attribute at all. A banner that comes and goes.
        case standard
        /// Stays on screen until the user acts on it. Understood by every
        /// Windows 10 and 11 build.
        case reminder
        /// Also breaks through Focus Assist. **Windows 11 only** — emitting it
        /// on Windows 10 is a schema violation that posts nothing.
        case urgent
    }

    /// The group every Tailscreen notice is filed under, so `RemoveByGroup`
    /// can clear the lot at teardown without touching another app's toasts.
    public static let group = "tailscreen"

    /// `AppNotification.Tag`'s limit. Exceeding it is a refusal, not a
    /// truncation.
    public static let maxTagLength = 64

    /// The action key for "the user clicked the toast itself, not a button".
    ///
    /// Distinct from every answer on purpose, and specifically distinct from
    /// deny: clicking a notification to look at it must never be read as a
    /// decision about a peer. It is the same rule `NoticeAction.dismiss`
    /// encodes on the portable side.
    public static let openActionKey = "open"

    // MARK: - Scenario

    /// Which scenario a notice gets, given what the desktop understands.
    ///
    /// - `blocksSomeone` is `SharerNoticeKind.blocksSomeone`: a person is
    ///   stuck *inside a running session*. Only these break through Focus
    ///   Assist, because the exemption is revoked per app and one over-eager
    ///   kind disarms the rest.
    /// - Anything else that can be *answered* still refuses to expire — an
    ///   approval prompt that times out silently leaves somebody waiting
    ///   forever with nobody aware of it.
    /// - A report expires like any other banner. There is nothing to answer.
    public static func scenario(
        blocksSomeone: Bool, actionable: Bool, supportsUrgent: Bool
    ) -> Scenario {
        guard actionable else { return .standard }
        // The Windows 10 fall-back is `reminder` rather than `standard`: the
        // urgent half of the request is what gets lost, not the "wait for an
        // answer" half, and losing both would be a worse notice than the one
        // this platform can actually render.
        if blocksSomeone { return supportsUrgent ? .urgent : .reminder }
        return .reminder
    }

    // MARK: - Activation arguments

    /// The string a press comes back as, through
    /// `ExtendedActivationKind.AppNotification`.
    ///
    /// A query string rather than the notice's `id`, because the id alone
    /// cannot say *which button* — and the two travel through the same single
    /// opaque attribute. Both halves are percent-encoded: a peer's identity is
    /// an IP or a hostname it chose itself, and one `&` in it would otherwise
    /// split into a third field and take the identity with it.
    public static func arguments(action: String, identity: String) -> String {
        "action=\(percentEncoded(action))&id=\(percentEncoded(identity))"
    }

    /// The inverse, for the host's activation handler.
    ///
    /// Returns nil for anything that is not one of ours — Windows delivers
    /// activation arguments from whatever posted them, and a launch we did not
    /// write must not be answered as if a viewer were waiting on it.
    public static func decodeArguments(_ raw: String) -> (action: String, identity: String)? {
        var action: String?
        var identity: String?
        for field in raw.split(separator: "&", omittingEmptySubsequences: true) {
            // `split(separator:maxSplits:)` rather than a plain split: a
            // percent-encoded value never contains a bare `=`, but a future
            // field might, and silently dropping its tail would be invisible.
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let value = percentDecoded(String(parts[1])) else { continue }
            switch parts[0] {
            case "action": action = value
            case "id": identity = value
            default: continue
            }
        }
        guard let action, !action.isEmpty, let identity else { return nil }
        return (action, identity)
    }

    // MARK: - Tag

    /// The tag a notice is posted under, and later withdrawn by.
    ///
    /// Reposting under the same tag REPLACES the toast in place — the Windows
    /// spelling of freedesktop's `replaces_id` — so the tag has to be a pure
    /// function of the notice's identity and nothing else.
    ///
    /// Identities that are already short and safe are used verbatim, because a
    /// readable tag is worth having when reading a trace. Everything else is
    /// folded to a fixed 64 characters with a hash suffix that keeps two long
    /// hostnames sharing a prefix apart — the case where a silent collision
    /// would withdraw the wrong person's prompt.
    public static func tag(for identity: String) -> String {
        if identity.count <= maxTagLength, !identity.isEmpty, identity.allSatisfy(isTagSafe) {
            return identity
        }
        let digits = 16
        let prefixBudget = maxTagLength - digits - 1
        let prefix = String(identity.prefix(prefixBudget).map { isTagSafe($0) ? $0 : "_" })
        return "\(prefix)-\(String(format: "%016llx", stableHash(identity)))"
    }

    private static func isTagSafe(_ character: Character) -> Bool {
        character.isASCII
            && (character.isLetter || character.isNumber || "-._:".contains(character))
    }

    /// FNV-1a over the UTF-8 bytes.
    ///
    /// Hand-folded rather than `Hasher`, which is salted per launch: a tag that
    /// changed between runs would post a second banner instead of replacing the
    /// first, and would never withdraw the one left behind by the previous run.
    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    // MARK: - Payload

    /// The complete toast XML for one notice.
    ///
    /// `identity` is threaded into every activation string, so whichever button
    /// is pressed — or the toast body itself — the host learns *who* it is
    /// about without a lookup table that could go stale.
    ///
    /// Silent by construction. macOS dropped `.default` on these same four
    /// posts because with system-audio sharing on, `excludesCurrentProcessAudio`
    /// drops only our *own* audio — so viewers hear every notification the
    /// sharer gets. Windows has no system-audio capture yet, so this is
    /// consistency ahead of the leak rather than a fix for one, and it costs a
    /// sound nobody wanted on a sharer-facing prompt.
    public static func xml(
        summary: String,
        body: String,
        buttons: [Button],
        scenario: Scenario,
        identity: String
    ) -> String {
        var toast = "<toast launch=\"\(escaped(arguments(action: openActionKey, identity: identity)))\""
        if scenario != .standard {
            toast += " scenario=\"\(scenario.rawValue)\""
        }
        toast += ">"

        toast += "<visual><binding template=\"ToastGeneric\">"
        toast += "<text>\(escaped(summary))</text>"
        // Omitted rather than emitted empty: a `ToastGeneric` binding with a
        // blank second line renders a gap under the title.
        if !body.isEmpty {
            toast += "<text>\(escaped(body))</text>"
        }
        toast += "</binding></visual>"

        if !buttons.isEmpty {
            toast += "<actions>"
            for button in buttons {
                // `foreground` is the only activation type an unpackaged app
                // gets: background activation needs a packaged background
                // task. The app is *activated*; whether its window comes
                // forward is then the host's call, which matters because
                // raising it mid-share is itself visible to viewers.
                toast += "<action content=\"\(escaped(button.label))\""
                toast += " arguments=\"\(escaped(arguments(action: button.key, identity: identity)))\""
                toast += " activationType=\"foreground\"/>"
            }
            toast += "</actions>"
        }

        toast += "<audio silent=\"true\"/>"
        toast += "</toast>"
        return toast
    }

    /// XML-escape for both text nodes and attribute values.
    ///
    /// Every one of the five, not the three that "obviously" matter: the
    /// payload puts caller-supplied text inside double-quoted attributes, so a
    /// quote in a peer's name closes the attribute and the document stops
    /// parsing.
    static func escaped(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }

    /// Percent-encode everything outside an unreserved set.
    ///
    /// Hand-rolled rather than `addingPercentEncoding(withAllowedCharacters:)`
    /// so the encoded form is identical on every platform this is tested and
    /// run on, and so `=` and `&` are unconditionally encoded — the whole point
    /// here, and both are allowed by several of Foundation's stock sets.
    static func percentEncoded(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            let scalar = UnicodeScalar(byte)
            let unreserved =
                (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39) || scalar == "-" || scalar == "." || scalar == "_"
                || scalar == "~"
            if unreserved {
                out.unicodeScalars.append(scalar)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// The inverse. Nil on a truncated or non-hex escape, rather than passing
    /// the mangled bytes on: an identity that decoded to *something else* would
    /// answer the wrong peer.
    static func percentDecoded(_ value: String) -> String? {
        let source = Array(value.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == UInt8(ascii: "%") {
                guard index + 2 < source.count,
                    let high = hexValue(source[index + 1]),
                    let low = hexValue(source[index + 2])
                else { return nil }
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(byte)
                index += 1
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
