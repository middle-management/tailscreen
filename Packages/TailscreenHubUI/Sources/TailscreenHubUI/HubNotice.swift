import SwiftCrossUI
import TailscreenL10n

/// A non-modal notice about a session that is STILL RUNNING — today the
/// decode-recovery ladder's terminal rung, "video has stalled".
///
/// Not a placard: dropping to the failed placard would end the session UI for
/// a condition the ladder treats as recoverable, where the last frame is
/// still worth showing.
///
/// A row above the video, not a floating card: an overlaid view swallows
/// clicks on WinUI (see `AnnotationToolbar`), and this one carries a button.
///
/// No Reconnect: the "Watching …" bar above already has Stop, and the screen
/// list behind it is where a redial starts — a second route to the same two
/// clicks would just be a second decision to make.
public struct ViewerNoticeBanner: View {
    let message: String
    let onDismiss: @MainActor @Sendable () -> Void

    public init(message: String, onDismiss: @escaping @MainActor @Sendable () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 10) {
            // Unicode, not an icon — no icon set on either backend; never the sole carrier of state.
            Text("⚠")
                .font(.callout)
            Text(message)
                .font(.callout)
            Spacer()
            Button("✕", action: onDismiss)
                .help(L("Dismiss notice"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        // The pending-viewer rows' amber: not chrome, not an error.
        .background(HubStyle.attentionFill)
    }
}
