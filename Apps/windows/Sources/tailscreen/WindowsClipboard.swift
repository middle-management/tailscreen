import Foundation

// The app's SECOND genuinely Windows-bound file, and — like `WinUIVideoView`
// beside it — it carries an `#else` so Linux CI still typechecks everything
// that calls it. There is nothing to decide here: the share card's Copy
// buttons hand over a string, and this puts it on the clipboard.
//
// WinRT rather than a C shim over `OpenClipboard`/`SetClipboardData`: the
// binding already exists in swift-winui's UWP module (`Clipboard.setContent`
// over a `DataPackage`), the app already links that module through WinUI, and
// a C target would be thirty lines of Win32 that only a Windows runner could
// ever compile. Fewer places for a forty-minute feedback loop to bite.
#if os(Windows)

import UWP

/// Put text on the Windows clipboard.
///
/// `flush()` is what makes it outlive this process: without it the
/// clipboard holds a reference to a `DataPackage` owned by an app that may
/// be about to quit, and pasting after that gets nothing. Stopping a share
/// and closing the window is exactly when somebody pastes the link they
/// just copied.
///
/// Best-effort: the WinRT bindings trap rather than throw, and there is no
/// useful thing to say to a person whose clipboard is momentarily held by
/// another process. The link stays selectable on the card either way.
@MainActor
func copyToClipboard(_ text: String) {
    let package = DataPackage()
    // No `requestedOperation`: it steers drag-and-drop and the share
    // sheet, not `Clipboard.setContent`, and its value is a C enum
    // imported under a mangled name — a line that buys nothing and could
    // only be proven to compile on a Windows runner.
    try? package.setText(text)
    Clipboard.setContent(package)
    Clipboard.flush()
}

#else

/// The stub Linux CI compiles. It exists so the whole view layer above it
/// typechecks off Windows; nothing calls it in a real run.
@MainActor
func copyToClipboard(_ text: String) {
    _ = text
}

#endif
