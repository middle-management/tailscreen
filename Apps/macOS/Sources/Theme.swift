import AppKit
import SwiftUI

/// Tailscreen's small shared design layer. The app stays close to native
/// macOS idiom (the reference is the Tailscale mac app: quiet neutral
/// surfaces, a strong heading, generous spacing), so this file only holds
/// the few identity decisions that should not be re-derived per view.
enum TSTheme {
    /// Deterministic per-name hue for monogram avatars, so a peer or
    /// account keeps its color across launches. Uses a djb2 hash over the
    /// UTF-8 bytes — Swift's `hashValue` is seeded per process and would
    /// reshuffle colors every launch.
    static func monogramColor(for name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .cyan]
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// Fetches and caches account avatars (Tailscale profile pictures, e.g.
/// GitHub avatars) keyed by URL string. In-memory only — a relaunch
/// refetches, which also picks up changed pictures. Misses render as
/// monograms, so a failed or slow fetch degrades invisibly.
@MainActor
final class AvatarStore: ObservableObject {
    static let shared = AvatarStore()

    @Published private(set) var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    /// Cached avatar for `urlString`, kicking a background fetch on the
    /// first miss. Publishes when the fetch lands so observing views
    /// re-render with the real picture.
    func avatar(for urlString: String?) -> NSImage? {
        guard let urlString, !urlString.isEmpty else { return nil }
        if let cached = images[urlString] { return cached }
        fetch(urlString)
        return nil
    }

    private func fetch(_ urlString: String) {
        guard !inFlight.contains(urlString), let url = URL(string: urlString) else { return }
        inFlight.insert(urlString)
        Task {
            defer { inFlight.remove(urlString) }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200,
                let image = NSImage(data: data)
            else { return }
            images[urlString] = image
        }
    }

    /// Aspect-fill `image` into a circle of `size` points — for
    /// `NSMenuItem.image`, which can't be clipped by SwiftUI.
    nonisolated static func circular(_ image: NSImage, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let source = image.size
            guard source.width > 0, source.height > 0 else { return false }
            NSBezierPath(ovalIn: rect).addClip()
            let scale = max(rect.width / source.width, rect.height / source.height)
            let drawSize = NSSize(width: source.width * scale, height: source.height * scale)
            let origin = NSPoint(
                x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
            image.draw(in: NSRect(origin: origin, size: drawSize))
            return true
        }
    }
}

/// Account avatar: the fetched profile picture when available, else the
/// deterministic monogram. Observing the store means the monogram swaps
/// to the real picture the moment its fetch lands.
struct AccountAvatar: View {
    @ObservedObject private var store = AvatarStore.shared
    let name: String
    let pictureURL: String?
    var size: CGFloat = 24

    var body: some View {
        if let image = store.avatar(for: pictureURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            MonogramAvatar(name: name, size: size)
        }
    }
}

/// Circular monogram avatar — first character of the display name over the
/// name's deterministic color. Used by the main window's toolbar account
/// menu; sized by the caller.
struct MonogramAvatar: View {
    let name: String
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle()
                .fill(TSTheme.monogramColor(for: name).gradient)
            Text(initial)
                .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initial: String {
        name.first.map { String($0).uppercased() } ?? "?"
    }

    /// AppKit rendering of the same avatar, for `NSMenuItem.image` — the
    /// account menu is a real `NSMenu` (SwiftUI `Menu` flattens custom row
    /// labels to plain text, so Tailscale-style two-line rows need AppKit).
    static func nsImage(name: String, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(TSTheme.monogramColor(for: name)).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let initial = name.first.map { String($0).uppercased() } ?? "?"
            let text = NSAttributedString(
                string: initial,
                attributes: [
                    .font: NSFont.systemFont(ofSize: size * 0.45, weight: .semibold),
                    .foregroundColor: NSColor.white
                ])
            let textSize = text.size()
            text.draw(
                at: NSPoint(
                    x: (rect.width - textSize.width) / 2,
                    y: (rect.height - textSize.height) / 2))
            return true
        }
        return image
    }
}
