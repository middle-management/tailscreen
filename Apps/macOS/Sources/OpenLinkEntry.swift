import Foundation

/// Pure decisions behind "Open Link on Sharer…" (both ends), kept out of the
/// views so `OpenLinkEntryTests` can pin them.
enum OpenLinkEntry {
    /// What a viewer's typed or pasted text sends, or nil if the sharer would
    /// drop it. Surrounding whitespace is trimmed (a copied link often
    /// carries a newline); anything inside is left to
    /// `OpenLinkPayload.isAcceptable`, which rejects rather than repairs.
    static func sendable(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenLinkPayload.isAcceptable(trimmed) ? trimmed : nil
    }

    /// The URL a sharer's Open click hands the browser. Re-checks the wire
    /// rules and the parsed scheme so nothing but http(s) can ever reach
    /// `NSWorkspace.open`, whatever the server let through.
    static func openableURL(_ string: String) -> URL? {
        guard OpenLinkPayload.isAcceptable(string), let url = URL(string: string),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}
