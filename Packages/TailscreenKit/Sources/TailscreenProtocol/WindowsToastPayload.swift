import Foundation

/// The Windows half of a sharer notice: the toast XML, the activation string a
/// button press comes back as, and the tag a notice is later withdrawn by.
///
/// On Windows the whole notification is one XML document handed to
/// `AppNotification`, so composing it correctly is the delivery-shaped
/// decision, and it's pure — lives here so Linux CI can test it with no
/// Windows runner in the loop.
///
/// What it deliberately does **not** know: the words. Those are
/// `SharerNoticeText`'s, already rendered by the time they arrive here.
///
/// **The three ways a toast quietly does nothing**, none producing an error,
/// each pinned by a test:
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

    /// The `scenario` attribute, how a toast asks to outlive the few seconds
    /// a banner normally gets. Spent per *app*, revocable by the user (like
    /// macOS's `.timeSensitive`), so the mapping below is deliberately
    /// stingy — see `scenario(blocksSomeone:…)`.
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
    /// Distinct from every answer, specifically deny: clicking to look at a
    /// notification must never be read as a decision. Same rule
    /// `NoticeAction.dismiss` encodes on the portable side.
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
        // Windows 10 falls back to `reminder`, not `standard`: only the
        // urgent half of the request is lost, not the "wait for an answer"
        // half.
        if blocksSomeone { return supportsUrgent ? .urgent : .reminder }
        return .reminder
    }

    // MARK: - Activation arguments

    /// The string a press comes back as, through
    /// `ExtendedActivationKind.AppNotification`.
    ///
    /// A query string, not the notice's `id` alone, since the id can't say
    /// *which button*, and both travel through one opaque attribute. Both
    /// halves are percent-encoded so an `&` in a peer's self-chosen hostname
    /// can't split into a third field.
    public static func arguments(action: String, identity: String) -> String {
        "action=\(percentEncoded(action))&id=\(percentEncoded(identity))"
    }

    /// The inverse, for the host's activation handler. Returns nil for
    /// anything that isn't ours — a launch we didn't write must not be
    /// answered as if a viewer were waiting on it.
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

    /// The tag a notice is posted under, and later withdrawn by. Reposting
    /// under the same tag REPLACES the toast in place, so the tag must be a
    /// pure function of the notice's identity.
    ///
    /// Short, safe identities are used verbatim for a readable trace.
    /// Everything else folds to 64 characters with a hash suffix, so two
    /// long hostnames sharing a prefix don't collide and withdraw the wrong
    /// person's prompt.
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

    /// FNV-1a over the UTF-8 bytes. Hand-folded, not `Hasher` (salted per
    /// launch): a tag changing between runs would post a second banner
    /// instead of replacing the first.
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
    /// `identity` is threaded into every activation string, so whichever
    /// button is pressed — or the toast body itself — the host learns *who*
    /// it's about with no lookup table to go stale.
    ///
    /// Silent by construction, matching macOS (which drops `.default` since
    /// system-audio sharing would otherwise leak the ding to viewers).
    /// Windows has no system-audio capture yet, so this is consistency ahead
    /// of the leak.
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
                // gets. The app is *activated*; whether its window comes
                // forward is the host's call, since raising it mid-share is
                // itself visible to viewers.
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

    /// XML-escape for both text nodes and attribute values. All five
    /// characters, not just the three that "obviously" matter: caller-supplied
    /// text sits inside double-quoted attributes, so an unescaped quote in a
    /// peer's name would close the attribute and break parsing.
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

    /// Percent-encode everything outside an unreserved set. Hand-rolled
    /// rather than `addingPercentEncoding(withAllowedCharacters:)` so `=`
    /// and `&` are unconditionally encoded — both are allowed by several of
    /// Foundation's stock sets, which would defeat the whole point.
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

    /// The inverse. Nil on a truncated or non-hex escape rather than passing
    /// mangled bytes on — a wrongly decoded identity would answer the wrong
    /// peer.
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
