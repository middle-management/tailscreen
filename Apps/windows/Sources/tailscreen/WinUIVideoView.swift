import Foundation
import SwiftCrossUI
import TailscreenL10n

import enum TailscreenProtocol.AnnotationRasterizer
import enum TailscreenProtocol.InputEvent
import struct TailscreenProtocol.KeyModifiers
import enum TailscreenProtocol.VideoColorRange
import enum TailscreenProtocol.ViewerPointerMapping
import enum TailscreenProtocol.ViewerZoomMath
import enum TailscreenProtocol.WindowsKeyCodeMapping
import class TailscreenViewer.FrameStore

// This is the app's ONLY genuinely Windows-bound file — the `#else` at the
// bottom is what lets Linux CI typecheck everything else, including
// `TailscreenWindowsApp.swift`'s result-builder body, which once failed on a
// Windows runner with "failed to produce diagnostic for expression".
//
// The interactive layer (drawing/zoom/remote control) follows the same rule:
// EVERY decision lives in `WindowsViewerInteraction` or the portable tier
// (`ViewerPointerMapping`, `ViewerZoomMath`, `AnnotationRasterizer`,
// `WindowsKeyCodeMapping`), all Linux-compiled and tested. What's left here
// is event plumbing: read a pointer, hand over four numbers.
#if os(Windows)

// Inside the guard: `CWinVideo` is a `.when(platforms: [.windows])`
// dependency, so a top-of-file import would break the `linux-app` typecheck.
import CWinVideo

import WinUI
// `WinUIElementRepresentable` lives in the BACKEND module — the seam between
// SwiftCrossUI and WinUI, so neither re-exports it.
import WinUIBackend
import WindowsFoundation

/// The video surface: a WinUI `Image` fed from a GPU-rendered
/// `SurfaceImageSource`, polling the portable `FrameStore` for the latest
/// decoded frame. YUV->RGB conversion happens on the GPU in `CWinVideo`,
/// replacing an earlier `WriteableBitmap` + `I420Converter` CPU path.
///
/// `SurfaceImageSource` rather than `SwapChainPanel`: swift-winui has no
/// `SwapChainPanel` binding. Its `ISurfaceImageSourceNative` hands D3D11 a
/// surface to render into, so the element stays an `Image` and only its
/// source changed. See plans/gpu-rendering-plan.md.
///
/// Zoom stays a `CompositeTransform` on the element (compositor applies it
/// for free); annotations still rasterize via the portable
/// `AnnotationRasterizer` into an overlay the shader composites in the same
/// pass, so they scale with the video.
///
/// `WinUIElementRepresentable` is swift-cross-ui's `NSViewRepresentable` analogue.
struct WinUIVideoView: WinUIElementRepresentable {
    typealias WinUIElementType = WinUI.Image

    let store: FrameStore
    /// Bumped by the app whenever a new frame lands, purely to make
    /// swift-cross-ui call `updateWinUIElement`. The frame itself travels
    /// through `store`, not through this.
    let generation: Int
    /// Drawing / zoom / remote-control state. Every decision it makes is
    /// portable and typechecked on Linux; this file only feeds it events.
    let interaction: WindowsViewerInteraction

    @MainActor
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    func makeWinUIElement(context: Context) -> WinUI.Image {
        let image = WinUI.Image()
        // Fill the pane; the sharer's aspect ratio is preserved by `uniform`
        // rather than by resizing the window, which the WinUI backend cannot do
        // anyway (`setSizeLimits` is unimplemented).
        image.stretch = .uniform
        context.coordinator.attachInput(to: image, interaction: interaction)
        return image
    }

    @MainActor
    func updateWinUIElement(_ element: WinUI.Image, context: Context) {
        context.coordinator.draw(from: store, into: element, interaction: interaction)
    }

    /// Take whatever the parent offers, falling back to 16:9. The frame's own
    /// size is deliberately NOT consulted: `stretch = .uniform` already
    /// letterboxes it, so sizing to the video would jump the layout on the
    /// first decoded frame. Overrides the protocol's default, which measures
    /// an `Image` with no source as zero and would collapse the pane.
    @MainActor
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        winUIElement: WinUI.Image,
        context: Context
    ) -> ViewSize {
        proposal.replacingUnspecifiedDimensions(by: ViewSize(640, 360))
    }

    /// Owns the image source across updates. Rebuilt only when the video size
    /// actually changes — recreating it per frame would allocate a
    /// full-resolution surface 60 times a second.
    @MainActor
    final class Coordinator {
        private var source: SurfaceImageSource?
        private var sourceWidth = 0
        private var sourceHeight = 0
        /// Set once `winvideo_init` succeeds. When it never does, `draw`
        /// gives up rather than falling back to a silent CPU path.
        private var gpuReady = false
        /// Reusable RGBA overlay for annotations, allocated only when
        /// somebody draws.
        private var overlay: [UInt8] = []
        /// The element's last laid-out size, for the letterbox and zoom math.
        private var lastVideoWidth = 0
        private var lastVideoHeight = 0
        /// Which gesture a pointer press is doing — decided at press time, so
        /// switching tools mid-drag can't reshape it.
        private var activeGesture: Gesture?
        private var lastPanPoint: CGPoint = .zero
        /// Which button opened the current `.controlling` drag. Remembered
        /// rather than re-read on release, since by release time nothing is
        /// pressed — a right-drag would otherwise send `mouseUp(.left)` and
        /// strand the right button down on the sharer's machine.
        private var pressedButton: InputEvent.MouseButton = .left

        private enum Gesture {
            case drawing
            case controlling
            case panning
        }

        func draw(
            from store: FrameStore, into element: WinUI.Image,
            interaction: WindowsViewerInteraction
        ) {
            guard let frame = store.current() else { return }
            lastVideoWidth = frame.width
            lastVideoHeight = frame.height

            if !gpuReady {
                gpuReady = winvideo_init() != 0
                guard gpuReady else { return }
            }
            // Device-lost recovery: a D3D11 device can be lost on a driver
            // update or GPU reset, and a black-and-stuck viewer is worse than
            // a slow one. Rebuild from scratch and let the next frame land.
            if winvideo_device_lost() != 0 {
                // Logged so recovery is visible in the wild — a viewer that
                // recovers silently and one that's wedged look identical
                // otherwise. Fires once per loss episode: `winvideo_reset`
                // clears the flag.
                print("[winvideo] device lost — rebuilding the D3D11 device")
                winvideo_reset()
                gpuReady = false
                source = nil
                sourceWidth = 0
                sourceHeight = 0
                return
            }

            if source == nil || sourceWidth != frame.width || sourceHeight != frame.height {
                // `isOpaque: true`: the shader writes alpha 1.0 over the whole
                // surface, so this lets XAML skip blending the video against
                // what's behind it.
                let fresh = SurfaceImageSource(
                    Int32(frame.width), Int32(frame.height), true)
                // A swift-winui class projection is a `WinRTClass`, which
                // wraps its COM pointer in `_inner` rather than inheriting
                // `IUnknown`, so `pUnk` isn't on the class itself. `thisPtr`
                // (the `IWinRTObject` bridge) is an `IInspectable`, which does
                // carry `pUnk` — same handoff `NotificationActivation` makes.
                // Don't use the projection's own `queryInterface`: on
                // `WinRTClass` it's `@_spi(WinRTImplements)`.
                //
                // `withExtendedLifetime` because `thisPtr` hands back a fresh
                // reference that must outlive the call.
                let inspectable = fresh.thisPtr
                let bound = withExtendedLifetime(inspectable) {
                    winvideo_bind_source(
                        UnsafeMutableRawPointer(inspectable.pUnk.borrow),
                        Int32(frame.width), Int32(frame.height))
                }
                guard bound != 0 else { return }
                source = fresh
                sourceWidth = frame.width
                sourceHeight = frame.height
                element.source = fresh
            }
            guard source != nil else { return }

            // Annotations rasterize into a dedicated RGBA overlay the shader
            // composites over the video in the same pass, so strokes scale
            // with the element's transform without needing a CPU BGRA frame.
            // The buffer is allocated on first use and reused.
            //
            // Ephemeral strokes (`.click` markers) age out on a clock, and
            // this per-frame composite is the only thing that ticks once the
            // ops stop arriving. Swept BEFORE the read so this frame already
            // reflects it; `expire` queues no repaint of its own.
            interaction.annotations.expire()
            let annotations = interaction.annotations.visibleAnnotations
            var overlayPointer: UnsafePointer<UInt8>?
            let overlayBytes = frame.width * frame.height * AnnotationRasterizer.bytesPerPixel
            if !annotations.isEmpty {
                if overlay.count != overlayBytes {
                    overlay = [UInt8](repeating: 0, count: overlayBytes)
                } else {
                    // Cleared rather than reallocated: a stroke that was undone
                    // must not persist as a ghost from the previous frame.
                    for i in overlay.indices { overlay[i] = 0 }
                }
                overlay.withUnsafeMutableBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    AnnotationRasterizer.draw(
                        annotations,
                        into: AnnotationRasterizer.Surface(
                            bgra: base,
                            stride: frame.width * AnnotationRasterizer.bytesPerPixel,
                            width: frame.width,
                            height: frame.height))
                }
            }

            frame.yPlane.withUnsafeBufferPointer { yBuf in
                frame.uPlane.withUnsafeBufferPointer { uBuf in
                    frame.vPlane.withUnsafeBufferPointer { vBuf in
                        overlay.withUnsafeBufferPointer { oBuf in
                            overlayPointer = annotations.isEmpty ? nil : oBuf.baseAddress
                            _ = winvideo_draw_yuv(
                                Int32(frame.width), Int32(frame.height),
                                yBuf.baseAddress, uBuf.baseAddress, vBuf.baseAddress,
                                overlayPointer,
                                frame.colorInfo.range == .full ? 1 : 0)
                        }
                    }
                }
            }

            applyZoom(to: element, interaction: interaction)
        }

        /// Project the portable zoom state onto the element's render
        /// transform, rather than cropping the source — composited by the
        /// same pass that already draws the Image, so zooming costs nothing
        /// per frame.
        private func applyZoom(to element: WinUI.Image, interaction: WindowsViewerInteraction) {
            let state = interaction.zoomState
            let transform = CompositeTransform()
            transform.scaleX = Double(state.scale)
            transform.scaleY = Double(state.scale)
            transform.translateX = Double(state.offset.x)
            transform.translateY = Double(state.offset.y)
            element.renderTransform = transform
            // Origin at the centre, matching `ViewerZoomMath`'s model — the
            // default (0, 0) would zoom toward the top-left corner.
            element.renderTransformOrigin = Point(x: 0.5, y: 0.5)
        }

        // MARK: Input

        /// Attach pointer + key handlers once, at element creation. The
        /// element is made focusable and takes focus on press, since a
        /// `WinUI.Image` is not a focus target by default and `keyDown`
        /// never fires without it.
        func attachInput(to element: WinUI.Image, interaction: WindowsViewerInteraction) {
            element.isTabStop = true
            element.isHitTestVisible = true

            element.pointerPressed.addHandler { [weak self] sender, args in
                self?.handlePressed(sender, args, interaction)
            }
            element.pointerMoved.addHandler { [weak self] sender, args in
                self?.handleMoved(sender, args, interaction)
            }
            element.pointerReleased.addHandler { [weak self] sender, args in
                self?.handleReleased(sender, args, interaction)
            }
            // A capture loss ends the gesture like a release, or dragging out
            // of the window leaves a button stuck down on the sharer's desktop.
            element.pointerCaptureLost.addHandler { [weak self] sender, args in
                self?.handleReleased(sender, args, interaction)
            }
            element.pointerWheelChanged.addHandler { [weak self] sender, args in
                self?.handleWheel(sender, args, interaction)
            }
            element.keyDown.addHandler { [weak self] sender, args in
                self?.handleKey(sender, args, interaction, down: true)
            }
            element.keyUp.addHandler { [weak self] sender, args in
                self?.handleKey(sender, args, interaction, down: false)
            }
            // Losing focus stops key-up events, so a held modifier would
            // stay "held" forever without this.
            element.lostFocus.addHandler { [weak self] _, _ in
                self?.clearModifiers()
            }
            element.doubleTapped.addHandler { [weak self] sender, args in
                guard let self, let element = sender as? WinUI.Image, let args else { return }
                // `getPosition` throws here; an unreadable anchor falls back
                // to the element's centre.
                let fit = self.fitRect(of: element)
                let anchor =
                    (try? args.getPosition(element)).map {
                        CGPoint(x: Double($0.x), y: Double($0.y))
                    } ?? CGPoint(x: fit.midX, y: fit.midY)
                interaction.smartMagnify(anchor: anchor, fit: fit)
            }
        }

        /// The aspect-fit rect the video occupies inside the element.
        /// `ViewerZoomMath` and the letterbox mapping must agree on this, or a
        /// click lands in one place and zooms about another —
        /// `ViewerPointerMapping.fitRect` is the one function both use.
        private func fitRect(of element: WinUI.Image) -> CGRect {
            ViewerPointerMapping.fitRect(
                paneSize: (width: element.actualWidth, height: element.actualHeight),
                videoSize: (width: lastVideoWidth, height: lastVideoHeight))
        }

        /// Pointer position as normalized `[0, 1]` over the video content.
        /// Takes loose `Double`s rather than a `Point`: WinRT's `Point`
        /// carries `Float`s and every caller has already widened them.
        private func normalized(
            x: Double, y: Double, in element: WinUI.Image
        ) -> (
            x: Double, y: Double
        ) {
            ViewerPointerMapping.normalize(
                point: (x: x, y: y),
                paneSize: (width: element.actualWidth, height: element.actualHeight),
                videoSize: (width: lastVideoWidth, height: lastVideoHeight))
        }

        /// Everything a pointer handler needs, resolved in one call. WinUI
        /// reports position and button state on a `PointerPoint`, and both
        /// `getCurrentPoint` and its `properties` can fail — resolving them
        /// together is one failure path instead of two.
        ///
        /// A point with no readable `properties` still yields a position: the
        /// button degrades to left rather than dropping the event — a wrong
        /// button beats a click that never arrives.
        private struct PointerSample {
            let x: Double
            let y: Double
            let button: InputEvent.MouseButton
            let wheelLines: Double
            let isHorizontalWheel: Bool
        }

        private static func sample(
            _ args: PointerRoutedEventArgs, _ element: WinUI.Image
        )
            -> PointerSample?
        {
            guard let point = try? args.getCurrentPoint(element) else { return nil }
            let x = Double(point.position.x)
            let y = Double(point.position.y)
            guard let properties = point.properties else {
                return PointerSample(
                    x: x, y: y, button: .left, wheelLines: 0, isHorizontalWheel: false)
            }
            let button: InputEvent.MouseButton =
                properties.isRightButtonPressed
                ? .right : (properties.isMiddleButtonPressed ? .middle : .left)
            return PointerSample(
                x: x, y: y, button: button,
                // `WHEEL_DELTA` is 120 per detent.
                wheelLines: Double(properties.mouseWheelDelta) / 120.0,
                isHorizontalWheel: properties.isHorizontalMouseWheel)
        }

        private func handlePressed(
            _ sender: Any?, _ args: PointerRoutedEventArgs?,
            _ interaction: WindowsViewerInteraction
        ) {
            guard let element = sender as? WinUI.Image, let args,
                let point = Self.sample(args, element)
            else { return }
            _ = try? element.focus(.pointer)
            _ = try? element.capturePointer(args.pointer)
            let norm = normalized(x: point.x, y: point.y, in: element)

            if interaction.activeTool != nil {
                activeGesture = .drawing
                interaction.annotations.beginStroke(at: CGPoint(x: norm.x, y: norm.y))
            } else if interaction.forwardsInput {
                activeGesture = .controlling
                pressedButton = point.button
                interaction.forward(
                    .mouseDown(
                        x: norm.x, y: norm.y,
                        button: point.button,
                        modifiers: modifiers()))
            } else if interaction.isZoomed {
                // Only while zoomed: at fit there's nothing to pan over.
                activeGesture = .panning
                lastPanPoint = CGPoint(x: point.x, y: point.y)
            } else {
                activeGesture = nil
            }
        }

        private func handleMoved(
            _ sender: Any?, _ args: PointerRoutedEventArgs?,
            _ interaction: WindowsViewerInteraction
        ) {
            guard let element = sender as? WinUI.Image, let args,
                let point = Self.sample(args, element)
            else { return }
            let norm = normalized(x: point.x, y: point.y, in: element)

            switch activeGesture {
            case .drawing:
                interaction.annotations.extendStroke(to: CGPoint(x: norm.x, y: norm.y))
            case .panning:
                let delta = CGSize(
                    width: point.x - lastPanPoint.x, height: point.y - lastPanPoint.y)
                lastPanPoint = CGPoint(x: point.x, y: point.y)
                interaction.pan(by: delta, fit: fitRect(of: element))
            case .controlling, nil:
                // Forwarded even with no button down, so hover still works.
                interaction.forward(.mouseMove(x: norm.x, y: norm.y))
            }
        }

        private func handleReleased(
            _ sender: Any?, _ args: PointerRoutedEventArgs?,
            _ interaction: WindowsViewerInteraction
        ) {
            guard let element = sender as? WinUI.Image else { return }
            defer { activeGesture = nil }
            switch activeGesture {
            case .drawing:
                interaction.annotations.endStroke()
            case .controlling:
                guard let args, let point = Self.sample(args, element) else { return }
                let norm = normalized(x: point.x, y: point.y, in: element)
                // The released button is no longer pressed, so the flags
                // read `.left` by fallthrough; use `pressedButton` instead.
                interaction.forward(
                    .mouseUp(
                        x: norm.x, y: norm.y,
                        button: pressedButton,
                        modifiers: modifiers()))
            case .panning, nil:
                break
            }
        }

        private func handleWheel(
            _ sender: Any?, _ args: PointerRoutedEventArgs?,
            _ interaction: WindowsViewerInteraction
        ) {
            guard let element = sender as? WinUI.Image, let args,
                let point = Self.sample(args, element), point.wheelLines != 0
            else { return }

            // Ctrl+wheel zooms, plain wheel scrolls the sharer's content when
            // a grant is held.
            if modifiers().contains(.control) || !interaction.forwardsInput {
                let step =
                    point.wheelLines > 0
                    ? ViewerZoomMath.menuZoomStep : 1 / ViewerZoomMath.menuZoomStep
                interaction.zoom(
                    by: step, anchor: CGPoint(x: point.x, y: point.y),
                    fit: fitRect(of: element))
            } else {
                let norm = normalized(x: point.x, y: point.y, in: element)
                // A tilt wheel reports on the SAME `mouseWheelDelta` field,
                // distinguished only by this flag.
                interaction.forward(
                    .scroll(
                        x: norm.x, y: norm.y,
                        deltaX: point.isHorizontalWheel ? point.wheelLines : 0,
                        deltaY: point.isHorizontalWheel ? 0 : point.wheelLines,
                        modifiers: modifiers()))
            }
        }

        private func handleKey(
            _ sender: Any?, _ args: KeyRoutedEventArgs?,
            _ interaction: WindowsViewerInteraction, down: Bool
        ) {
            guard let args else { return }
            // VK → HID, the same table the Windows sharer injects with, read
            // in the other direction. An unmapped key is dropped, never guessed at.
            guard let usage = WindowsKeyCodeMapping.hidUsage(forVirtualKey: UInt16(args.key.rawValue))
            else { return }
            // Modifier keys update the tracked snapshot rather than being
            // forwarded standalone — their held state rides every event's
            // `modifiers` field. Tracked BEFORE the drop, or the first Ctrl+C
            // would send C with no Ctrl.
            guard !trackModifier(usage: usage, down: down) else { return }
            interaction.forward(
                down
                    ? .keyDown(key: usage, modifiers: modifiers())
                    : .keyUp(key: usage, modifiers: modifiers()))
        }

        /// The modifier snapshot that rides every event. TRACKED from the key
        /// events this element already receives, rather than queried from
        /// the system: `CoreWindow` doesn't exist in a WinAppSDK app, and the
        /// alternatives vary by binding version. Modifiers held BEFORE this
        /// element took focus are unknown, hence `clearModifiers` on focus loss.
        private var trackedModifiers: KeyModifiers = []

        /// Update the tracked set from a modifier key event. Returns true
        /// when the key WAS a modifier, so the caller can drop it rather than
        /// forwarding it. Shared logic is `KeyModifiers.trackHIDKeyEvent`,
        /// also used by the GTK viewer.
        private func trackModifier(usage: UInt16, down: Bool) -> Bool {
            trackedModifiers.trackHIDKeyEvent(usage: usage, down: down)
        }

        /// Forget every held modifier. Wired to focus loss — see
        /// `trackedModifiers`.
        func clearModifiers() { trackedModifiers = [] }

        private func modifiers() -> KeyModifiers { trackedModifiers }

    }
}

#else

/// Off Windows there is no WinUI to host, so the video surface is a
/// placeholder with the same name and initializer, so the rest of the app
/// compiles somewhere a Windows runner isn't required.
struct WinUIVideoView: View {
    let store: FrameStore
    let generation: Int
    let interaction: WindowsViewerInteraction

    var body: some View {
        Text(L("Video is available on Windows only."))
    }
}

#endif
