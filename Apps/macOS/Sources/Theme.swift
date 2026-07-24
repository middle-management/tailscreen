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
}
