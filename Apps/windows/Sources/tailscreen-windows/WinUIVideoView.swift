import Foundation
import SwiftCrossUI
import WinUI

import class TailscreenViewer.FrameStore
import enum TailscreenViewer.I420Converter

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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeWinUIElement(context: Context) -> WinUI.Image {
        let image = WinUI.Image()
        // Fill the pane; the sharer's aspect ratio is preserved by `uniform`
        // rather than by resizing the window, which the WinUI backend cannot do
        // anyway (`setSizeLimits` is unimplemented).
        image.stretch = .uniform
        return image
    }

    func updateWinUIElement(_ element: WinUI.Image, context: Context) {
        context.coordinator.draw(from: store, into: element)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        winUIElement: WinUI.Image,
        context: Context
    ) -> ViewSize {
        // Take whatever it is given: the frame's own size is irrelevant to
        // layout once `stretch = .uniform` letterboxes it.
        ViewSize(
            size: SIMD2(
                proposal.width ?? 640,
                proposal.height ?? 360
            ),
            idealSize: SIMD2(640, 360),
            minimumWidth: 160,
            minimumHeight: 90,
            maximumWidth: nil,
            maximumHeight: nil
        )
    }

    /// Owns the bitmap across updates. Recreating a `WriteableBitmap` per frame
    /// would allocate a full-resolution surface 60 times a second; it is rebuilt
    /// only when the video size actually changes.
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
