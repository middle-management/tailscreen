import SwiftCrossUI
import TailscreenL10n

/// A non-modal notice about a session that is STILL RUNNING — today the
/// decode-recovery ladder's terminal rung, "video has stalled".
///
/// The point of it is what it is not: a placard. Both swift-cross-ui viewers
/// answered a stall by dropping to the failed placard, which takes the picture
/// away and ends the session's UI — for a condition the ladder itself treats
/// as recoverable, where the last frame is still the most useful thing on
/// screen and one successful decode would put the stream back. The macOS
/// viewer has said so over the frozen frame since it replaced its mid-session
/// alerts; this is that banner, for the two hosts that had nothing.
///
/// Two deliberate differences from `ViewerNoticeBanner` on macOS.
///
/// It is a ROW above the video rather than a floating top-center card. An
/// overlaid view swallows clicks on the WinUI backend (see `AnnotationToolbar`'s
/// note on the same problem), and this one carries a button, so floating it
/// would work on GTK and be inert on Windows. A full-width strip also reads
/// correctly on the Windows viewer, whose chrome is stacked rather than
/// layered.
///
/// It offers no Reconnect. The macOS viewer is a separate window with no list
/// behind it, so its banner has to carry the way out; here the "Watching …"
/// bar directly above this one has Stop, and behind it is the screen list a
/// redial starts from. A second, differently-worded route to the same two
/// clicks is not an affordance, it is a decision to make.
public struct ViewerNoticeBanner: View {
    let message: String
    let onDismiss: @MainActor @Sendable () -> Void

    public init(message: String, onDismiss: @escaping @MainActor @Sendable () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 10) {
            // Unicode rather than an icon, the same reasoning (and the same
            // absence of an icon set on both backends) as the annotation
            // toolbar's glyphs. Never the only carrier of the state — the
            // sentence beside it says the whole thing.
            Text("⚠")
                .font(.callout)
            // Uncolored on purpose: this is the notice's own text, and
            // HubStyle leaves primary text following the host's foreground.
            Text(message)
                .font(.callout)
            Spacer()
            Button("✕", action: onDismiss)
                .help(L("Dismiss notice"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        // The "waiting on you" amber the pending-viewer rows use: a strip that
        // is not chrome and not an error, which is exactly what it is.
        .background(HubStyle.attentionFill)
    }
}
