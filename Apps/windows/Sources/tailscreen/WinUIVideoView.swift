import Foundation
import SwiftCrossUI

import class TailscreenViewer.FrameStore
import enum TailscreenViewer.I420Converter

// This is the app's ONLY genuinely Windows-bound file, and the `#else` at the
// bottom is what lets Linux CI typecheck everything else in the app —
// including `TailscreenWindowsApp.swift`, whose 90-line result-builder body
// once failed on a Windows runner with "failed to produce diagnostic for
// expression" after a forty-minute build. Everything the app does apart from
// blitting a frame is portable, and there is no reason for a one-line type
// error in it to be discoverable only on Windows.
#if os(Windows)

import WinUI
// `WinUIElementRepresentable` lives in the BACKEND module, not in SwiftCrossUI
// and not in WinUI — it is the seam between the two, so neither re-exports it.
import WinUIBackend

/// The video surface: a WinUI `Image` fed from a `WriteableBitmap`, polling the
/// portable `FrameStore` for the latest decoded frame.
///
/// `Image` + `WriteableBitmap` rather than `SwapChainPanel` + D3D11 on purpose.
/// It is the slow answer and the correct one: it makes "pixels on screen" a
/// small debuggable increment, it has no device-lost failure mode to handle,
/// and it can be verified by reading the bitmap back. Because the hand-off is
/// `FrameStore` — which is portable and already used by the GTK renderer — a
/// later `SwapChainPanel` implementation replaces this file without touching
/// the decoder, the session, or the transport.
///
/// `WinUIElementRepresentable` is swift-cross-ui's `NSViewRepresentable`
/// analogue: any `FrameworkElement` can be hosted, and `Image` is one.
struct WinUIVideoView: WinUIElementRepresentable {
    typealias WinUIElementType = WinUI.Image

    let store: FrameStore
    /// Bumped by the app whenever a new frame lands, purely to make
    /// swift-cross-ui call `updateWinUIElement`. The frame itself travels
    /// through `store`, not through this.
    let generation: Int

    @MainActor
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    func makeWinUIElement(context: Context) -> WinUI.Image {
        let image = WinUI.Image()
        // Fill the pane; the sharer's aspect ratio is preserved by `uniform`
        // rather than by resizing the window, which the WinUI backend cannot do
        // anyway (`setSizeLimits` is unimplemented).
        image.stretch = .uniform
        return image
    }

    @MainActor
    func updateWinUIElement(_ element: WinUI.Image, context: Context) {
        context.coordinator.draw(from: store, into: element)
    }

    /// Take whatever the parent offers, falling back to 16:9 when a dimension is
    /// unspecified. The frame's own size is deliberately NOT consulted: with
    /// `stretch = .uniform` the element letterboxes itself, so sizing to the
    /// video would make the layout jump on the first decoded frame and again on
    /// every resolution change.
    ///
    /// This overrides the protocol's default, which measures the element — an
    /// `Image` with no source yet measures zero, which would collapse the pane
    /// before the stream starts.
    @MainActor
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        winUIElement: WinUI.Image,
        context: Context
    ) -> ViewSize {
        proposal.replacingUnspecifiedDimensions(by: ViewSize(640, 360))
    }

    /// Owns the bitmap across updates. Recreating a `WriteableBitmap` per frame
    /// would allocate a full-resolution surface 60 times a second; it is rebuilt
    /// only when the video size actually changes.
    @MainActor
    final class Coordinator {
        private var bitmap: WriteableBitmap?
        private var bitmapWidth = 0
        private var bitmapHeight = 0

        func draw(from store: FrameStore, into element: WinUI.Image) {
            guard let frame = store.current() else { return }

            if bitmap == nil || bitmapWidth != frame.width || bitmapHeight != frame.height {
                let fresh = WriteableBitmap(Int32(frame.width), Int32(frame.height))
                bitmap = fresh
                bitmapWidth = frame.width
                bitmapHeight = frame.height
                element.source = fresh
            }
            guard let bitmap else { return }

            // `IBuffer` refines `IBufferByteAccess` in the WinRT bindings, so the
            // backing store is reachable without hand-rolled COM interop. The
            // pointer is valid only while the buffer is alive, hence the tight
            // scope here.
            guard let buffer = bitmap.pixelBuffer,
                let bytes = try? buffer.buffer
            else { return }

            guard I420Converter.convert(frame, into: bytes) else { return }
            try? bitmap.invalidate()
        }
    }
}

#else

/// Off Windows there is no WinUI to host, so the video surface is a placeholder
/// with the same name and the same initializer.
///
/// It exists purely so the rest of the app compiles somewhere a Windows runner
/// is not required — the same trick every C shim in this port uses (`ts_wgc`,
/// `ts_overlay`, `ts_sendinput` all have off-Windows stubs), applied one layer
/// up. Nothing renders it: no `#if`-free code path reaches this on a platform
/// that could show it.
struct WinUIVideoView: View {
    let store: FrameStore
    let generation: Int

    var body: some View {
        Text("Video is available on Windows only.")
    }
}

#endif
