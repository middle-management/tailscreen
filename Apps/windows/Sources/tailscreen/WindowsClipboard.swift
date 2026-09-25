import Foundation

// Windows-bound, with an `#else` so Linux CI still typechecks everything
// that calls it.
//
// WinRT rather than a C shim over `OpenClipboard`/`SetClipboardData`: the
// binding already exists in swift-winui's UWP module and the app already
// links it through WinUI.
#if os(Windows)

import UWP

/// Put text on the Windows clipboard. `flush()` makes it outlive this
/// process — without it the clipboard holds a reference to a `DataPackage`
/// owned by an app that may be about to quit.
///
/// Best-effort: the WinRT bindings trap rather than throw. The link stays
/// selectable on the card either way.
@MainActor
func copyToClipboard(_ text: String) {
    let package = DataPackage()
    // No `requestedOperation`: it steers drag-and-drop, not `Clipboard.setContent`.
    try? package.setText(text)
    Clipboard.setContent(package)
    Clipboard.flush()
}

#else

/// The stub Linux CI compiles, so the view layer above it typechecks off Windows.
@MainActor
func copyToClipboard(_ text: String) {
    _ = text
}

#endif
