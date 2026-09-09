import CGtk4Sys
import Foundation

/// Put text on the desktop's clipboard.
///
/// The share card's Copy buttons, and nothing else so far. It exists because
/// neither swift-cross-ui nor `TailscreenHubUI` can reach a clipboard —
/// the card takes an `onCopy` seam and each host fills it — and because the
/// alternative shipped for a while and was bad: a 120-character token
/// rendered as selectable text wrapping over three lines, twice, to be
/// dragged over with a mouse without clipping a character.
///
/// Straight to GDK rather than through swift-cross-ui's `Gtk` bindings: they
/// wrap widgets, not the display's clipboard, and this is two calls. GTK4
/// owns the transfer after `set_text` copies the string, so nothing here has
/// to outlive the call.
///
/// Best-effort by design — there is no error to report and no useful thing to
/// say if a display is somehow absent (a headless self-test, an X server that
/// went away). The link stays selectable in the card either way, which is the
/// fallback a host with no clipboard at all gets.
@MainActor
func copyToClipboard(_ text: String) {
    guard let display = gdk_display_get_default() else { return }
    gdk_clipboard_set_text(gdk_display_get_clipboard(display), text)
}
