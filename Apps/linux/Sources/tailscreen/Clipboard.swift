import CGtk4Sys
import Foundation

/// Put text on the desktop's clipboard, for the share card's Copy buttons.
///
/// Straight to GDK rather than swift-cross-ui's `Gtk` bindings, which wrap
/// widgets, not the display's clipboard.
///
/// Best-effort: no error to report if a display is absent (headless
/// self-test, X server gone); the link stays selectable in the card either
/// way.
@MainActor
func copyToClipboard(_ text: String) {
    guard let display = gdk_display_get_default() else { return }
    gdk_clipboard_set_text(gdk_display_get_clipboard(display), text)
}
