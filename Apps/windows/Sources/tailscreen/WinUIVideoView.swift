import Foundation
import SwiftCrossUI
import TailscreenL10n

import enum TailscreenProtocol.AnnotationRasterizer
import enum TailscreenProtocol.InputEvent
import struct TailscreenProtocol.KeyModifiers
import enum TailscreenProtocol.ViewerPointerMapping
import enum TailscreenProtocol.ViewerZoomMath
import enum TailscreenProtocol.WindowsKeyCodeMapping
// Moved down to the portable tier when the SHARER's preview thumbnail needed
// the same maths: this blit is one of its two callers now, not its owner.
import CWinVideo
import class TailscreenViewer.FrameStore

// This is the app's ONLY genuinely Windows-bound file, and the `#else` at the
// bottom is what lets Linux CI typecheck everything else in the app —
// including `TailscreenWindowsApp.swift`, whose 90-line result-builder body
// once failed on a Windows runner with "failed to produce diagnostic for
// expression" after a forty-minute build. Everything the app does apart from
// blitting a frame is portable, and there is no reason for a one-line type
// error in it to be discoverable only on Windows.
//
// The interactive layer added for the viewer's drawing / zoom / remote control
// follows the same rule and pushes it harder: EVERY decision lives in
// `WindowsViewerInteraction` (state machine, gate, ordering) or in the portable
// tier (`ViewerPointerMapping` letterbox math, `ViewerZoomMath` geometry,
// `AnnotationRasterizer` strokes, `WindowsKeyCodeMapping` VK→HID), all of which
// Linux compiles and tests. What is left here is event plumbing: read a
// pointer, hand over four numbers.
#if os(Windows)

import WinUI
// `WinUIElementRepresentable` lives in the BACKEND module, not in SwiftCrossUI
// and not in WinUI — it is the seam between the two, so neither re-exports it.
import WinUIBackend
import WindowsFoundation

/// The video surface: a WinUI `Image` fed from a GPU-rendered `SurfaceImageSource`, polling the
/// portable `FrameStore` for the latest decoded frame.
///
/// `Image` + `SurfaceImageSource`, with the YUV->RGB conversion on the GPU in
/// `CWinVideo`. This replaced `Image` + `WriteableBitmap` + `I420Converter`,
/// which converted ~7 MP on the CPU and uploaded a full BGRA frame per frame on
/// the UI thread — the only CPU colour-conversion left in the project once the
/// GTK viewer moved to a GL shader.
///
/// `SurfaceImageSource` rather than `SwapChainPanel`: swift-winui has no
/// `SwapChainPanel` binding, and `WinUIElementRepresentable` needs a
/// Swift-typed element. `SurfaceImageSource` is bound, and its
/// `ISurfaceImageSourceNative` (from the dependency's bundled
/// microsoft.ui.xaml.media.dxinterop.h) hands D3D11 a surface to render into —
/// so the element stays an `Image` and only its *source* changed. See
/// plans/gpu-rendering-plan.md for the trade-off that buys.
///
/// Two things deliberately stayed on the paths that were already free. Zoom is
/// still a `CompositeTransform` on the element, because the compositor applies
/// it for nothing; putting it in the shader would duplicate working GPU work.
/// And annotations are still rasterized by the portable `AnnotationRasterizer`,
/// into a reusable RGBA overlay the shader composites in the same pass — so they
/// remain part of the picture and keep scaling with the video, which is the
/// property the old draw-into-the-bitmap approach had and was worth keeping.
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

    /// Owns the image source across updates. Recreating a `SurfaceImageSource`
    /// per frame would allocate a full-resolution surface 60 times a second; it
    /// is rebuilt only when the video size actually changes.
    @MainActor
    final class Coordinator {
        private var source: SurfaceImageSource?
        private var sourceWidth = 0
        private var sourceHeight = 0
        /// Set once `winvideo_init` has succeeded. When it never does — no D3D11
        /// device at all — `draw` gives up rather than falling back: a silent CPU
        /// path would hide exactly the failure this replaced, and the log line
        /// `CWinVideo` prints is the diagnosis.
        private var gpuReady = false
        /// Reusable RGBA overlay for annotations, allocated only when somebody
        /// draws. A session with an empty canvas uploads three planes; the fourth
        /// texture costs nothing until there is something in it.
        private var overlay: [UInt8] = []
        /// The element's last laid-out size, for the letterbox and zoom math.
        /// Read from the element on each event rather than cached across them:
        /// the pane resizes with the window.
        private var lastVideoWidth = 0
        private var lastVideoHeight = 0
        /// Whether a pointer press is currently down on the surface, and what
        /// it is doing. A drag is one gesture, and which gesture it is has to be
        /// decided at press time — switching tools mid-drag must not reshape it.
        private var activeGesture: Gesture?
        private var lastPanPoint: CGPoint = .zero
        /// Which button opened the current `.controlling` drag.
        ///
        /// Remembered rather than re-read on release, because the button-state
        /// flags say what is *currently* pressed and by release time nothing
        /// is: a right-drag would otherwise send `mouseDown(.right)` followed
        /// by `mouseUp(.left)` and strand the right button down on the
        /// sharer's machine — the same stuck-button failure `SendInputInjector`
        /// synthesizes a button-up to avoid on revoke.
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
            // Device-lost recovery. `WriteableBitmap` could not lose its device;
            // a D3D11 one can, on a driver update or a GPU reset, and a viewer
            // that goes black and stays black is worse than a slow one. Rebuild
            // from scratch and let the next frame land.
            if winvideo_device_lost() != 0 {
                winvideo_reset()
                gpuReady = false
                source = nil
                sourceWidth = 0
                sourceHeight = 0
                return
            }

            if source == nil || sourceWidth != frame.width || sourceHeight != frame.height {
                let fresh = SurfaceImageSource(Int32(frame.width), Int32(frame.height))
                // The QueryInterface for `ISurfaceImageSourceNative` happens in
                // C++, so no IID is spelled in Swift; all this side owes is a
                // valid `IUnknown*` for the WinRT object.
                guard let unknown = fresh.queryInterface(IID_IUnknown) else { return }
                let bound = unknown.borrow { ptr in
                    winvideo_bind_source(
                        UnsafeMutableRawPointer(ptr), Int32(frame.width),
                        Int32(frame.height))
                }
                guard bound != 0 else { return }
                source = fresh
                sourceWidth = frame.width
                sourceHeight = frame.height
                element.source = fresh
            }
            guard source != nil else { return }

            // Annotations still go through the portable `AnnotationRasterizer`
            // — the same tested code the old bitmap path used — but into a
            // dedicated RGBA overlay the shader composites over the video in the
            // same pass, instead of into the converted frame. Same visible
            // result and the same property worth keeping (strokes are part of
            // the picture, so they scale with the element's transform), without
            // needing a CPU BGRA frame to draw into.
            //
            // The buffer is allocated on first use and reused; a session where
            // nobody draws pays one `isEmpty` check and uploads three planes
            // rather than four.
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
                            bgra: UnsafeMutableRawBufferPointer(
                                start: base, count: buf.count),
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
                                overlayPointer)
                        }
                    }
                }
            }

            applyZoom(to: element, interaction: interaction)
        }

        /// Project the portable zoom state onto the element's render transform.
        ///
        /// A `RenderTransform` rather than cropping the source: it is composited
        /// by the same pass that already draws the Image, so zooming costs
        /// nothing per frame, and it scales the annotations with the video
        /// because the shader composites them into the same surface.
        private func applyZoom(to element: WinUI.Image, interaction: WindowsViewerInteraction) {
            let state = interaction.zoomState
            let transform = CompositeTransform()
            transform.scaleX = Double(state.scale)
            transform.scaleY = Double(state.scale)
            transform.translateX = Double(state.offset.x)
            transform.translateY = Double(state.offset.y)
            element.renderTransform = transform
            // Origin at the centre, matching `ViewerZoomMath`'s model: it
            // magnifies about the fit rect's centre and expresses pan as an
            // offset from it. With the default (0, 0) origin the same numbers
            // would zoom toward the top-left corner.
            element.renderTransformOrigin = Point(x: 0.5, y: 0.5)
        }

        // MARK: Input

        /// Attach pointer + key handlers once, at element creation.
        ///
        /// The element is made focusable and takes focus on press, because a
        /// `WinUI.Image` is not a focus target by default and `keyDown` never
        /// fires on something that cannot be focused — remote-control typing
        /// would silently do nothing while the pointer worked fine.
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
            // A capture loss ends the gesture exactly like a release. Without
            // it, dragging out of the window and letting go leaves the stroke
            // live forever and — worse, under a control grant — leaves a button
            // held down on the sharer's desktop.
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
            // An element that loses focus stops receiving key-up events, so a
            // modifier held at that moment would stay "held" forever — and
            // silently turn the next plain click into a modified one.
            element.lostFocus.addHandler { [weak self] _, _ in
                self?.clearModifiers()
            }
            element.doubleTapped.addHandler { [weak self] sender, args in
                guard let self, let element = sender as? WinUI.Image, let args else { return }
                // `DoubleTappedRoutedEventArgs` DOES carry `getPosition` — it
                // is `PointerRoutedEventArgs` that does not — but it throws.
                // An unreadable anchor falls back to the element's centre,
                // which is where a fit-to-window zoom would land anyway.
                let fit = self.fitRect(of: element)
                let anchor =
                    (try? args.getPosition(element)).map {
                        CGPoint(x: Double($0.x), y: Double($0.y))
                    } ?? CGPoint(x: fit.midX, y: fit.midY)
                interaction.smartMagnify(anchor: anchor, fit: fit)
            }
        }

        /// The aspect-fit rect the video occupies inside the element, in the
        /// element's own coordinates.
        ///
        /// `ViewerZoomMath` works against this rather than the whole pane, and
        /// so does the letterbox mapping — they have to agree, or a click lands
        /// in one place and zooms about another.
        private func fitRect(of element: WinUI.Image) -> CGRect {
            let paneWidth = element.actualWidth
            let paneHeight = element.actualHeight
            guard paneWidth > 0, paneHeight > 0, lastVideoWidth > 0, lastVideoHeight > 0 else {
                return CGRect(x: 0, y: 0, width: paneWidth, height: paneHeight)
            }
            let frameAspect = Double(lastVideoWidth) / Double(lastVideoHeight)
            let paneAspect = paneWidth / paneHeight
            var width = paneWidth
            var height = paneHeight
            if frameAspect > paneAspect {
                height = paneWidth / frameAspect
            } else {
                width = paneHeight * frameAspect
            }
            return CGRect(
                x: (paneWidth - width) / 2, y: (paneHeight - height) / 2,
                width: width, height: height)
        }

        /// Pointer position as normalized `[0, 1]` over the video content.
        ///
        /// Takes loose `Double`s rather than a `Point` because WinRT's
        /// `Point` carries `Float`s and every caller has already had to widen
        /// them — `CGPoint` and `ViewerPointerMapping` both speak `Double`.
        private func normalized(x: Double, y: Double, in element: WinUI.Image) -> (
            x: Double, y: Double
        ) {
            ViewerPointerMapping.normalize(
                point: (x: x, y: y),
                paneSize: (width: element.actualWidth, height: element.actualHeight),
                videoSize: (width: lastVideoWidth, height: lastVideoHeight))
        }

        /// Everything a pointer handler needs, resolved in one call.
        ///
        /// WinUI reports position *and* button state on a `PointerPoint`, not
        /// as fields on the event args: `PointerRoutedEventArgs` has no
        /// `getPosition` at all (that lives on the *tapped* args, which is a
        /// different event). `getCurrentPoint` throws and its `properties` is
        /// optional, so resolving both at once is one failure path instead of
        /// three.
        ///
        /// A point with no readable `properties` still yields a position: the
        /// button degrades to left rather than dropping the event, because a
        /// click that arrives as the wrong button is a bad day while a click
        /// that never arrives — with the pointer visibly moving — is a broken
        /// feature with no error anywhere.
        private struct PointerSample {
            let x: Double
            let y: Double
            let button: InputEvent.MouseButton
            let wheelLines: Double
            let isHorizontalWheel: Bool
        }

        private static func sample(_ args: PointerRoutedEventArgs, _ element: WinUI.Image)
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
                // `WHEEL_DELTA` is 120 per detent on both ends of this wire.
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
                // Only while zoomed: at fit there is nothing to pan over, and
                // treating a plain click as a pan gesture would swallow it.
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
                // Moves are forwarded even with no button down — a remote
                // pointer that only moves while dragging cannot hover, and
                // hover is most of what a pointer does.
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
                // The released button is no longer *pressed*, so the flags read
                // `.left` by fallthrough. That is the same button the press
                // reported for every single-button drag, which is the only kind
                // a pointer capture delivers here.
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

            // Ctrl+wheel zooms, plain wheel scrolls the sharer's content when a
            // grant is held. The split matters: without it, zooming would be
            // unreachable while controlling, and scrolling unreachable while
            // not.
            if modifiers().contains(.control) || !interaction.forwardsInput {
                let step =
                    point.wheelLines > 0
                    ? ViewerZoomMath.menuZoomStep : 1 / ViewerZoomMath.menuZoomStep
                interaction.zoom(
                    by: step, anchor: CGPoint(x: point.x, y: point.y),
                    fit: fitRect(of: element))
            } else {
                let norm = normalized(x: point.x, y: point.y, in: element)
                // A tilt wheel reports on the SAME `mouseWheelDelta` field and
                // is distinguished only by this flag. Without the split a
                // horizontal scroll arrives at the sharer as a vertical one,
                // which is a wrong action rather than a missing one.
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
            // VK → HID, through the same table the Windows *sharer* injects
            // with, read in the other direction. Nothing native reaches the
            // wire; an unmapped key is dropped rather than guessed at, exactly
            // as every injector in this repo drops one.
            guard let usage = WindowsKeyCodeMapping.hidUsage(forVirtualKey: UInt16(args.key.rawValue))
            else { return }
            // Modifier keys update the tracked snapshot and are NOT forwarded
            // as standalone events — their held state rides every event's
            // `modifiers` field, which keeps a mid-stream join stateless and
            // stops a dropped connection stranding a modifier down on the
            // sharer's machine. Tracked BEFORE the drop, or the very first
            // Ctrl+C would send C with no Ctrl.
            guard !trackModifier(usage: usage, down: down) else { return }
            interaction.forward(
                down
                    ? .keyDown(key: usage, modifiers: modifiers())
                    : .keyUp(key: usage, modifiers: modifiers()))
        }

        /// The modifier snapshot that rides every event.
        ///
        /// TRACKED from the key events this element already receives, rather
        /// than queried from the system. The obvious query — `CoreWindow` —
        /// does not exist in a WinAppSDK app at all (it is UWP), and the
        /// alternatives (`InputKeyboardSource`, `PointerRoutedEventArgs`'
        /// modifier field) vary by binding version, which is a bet this file
        /// cannot check on Linux and costs forty minutes per attempt to check
        /// on Windows. Tracking uses only `args.key`, which is already in hand
        /// — no extra API surface, and identical on both architectures.
        ///
        /// The cost is that modifiers held BEFORE this element took focus are
        /// unknown. That is why `clearModifiers` exists and is wired to focus
        /// loss: an unknown modifier state must decay to "none held", never
        /// persist as a phantom Ctrl that silently turns the viewer's next
        /// click into a Ctrl-click on the sharer's desktop.
        private var trackedModifiers: KeyModifiers = []

        /// Update the tracked set from a modifier key event. Returns true when
        /// the key WAS a modifier, so the caller can drop it rather than
        /// forwarding it — their held state rides every event's `modifiers`
        /// field, which is what keeps a mid-stream join stateless.
        private func trackModifier(usage: UInt16, down: Bool) -> Bool {
            let flag: KeyModifiers
            switch usage {
            case 0xE1, 0xE5: flag = .shift
            case 0xE0, 0xE4: flag = .control
            case 0xE2, 0xE6: flag = .alt
            case 0xE3, 0xE7: flag = .meta
            case 0x39:
                // Caps Lock is a TOGGLE, not a held key: its down-event means
                // the state flipped, and there is no up-event to clear it.
                if down { trackedModifiers.formSymmetricDifference(.capsLock) }
                return true
            default: return false
            }
            if down {
                trackedModifiers.insert(flag)
            } else {
                trackedModifiers.remove(flag)
            }
            return true
        }

        /// Forget every held modifier. Wired to focus loss — see
        /// `trackedModifiers`.
        func clearModifiers() { trackedModifiers = [] }

        private func modifiers() -> KeyModifiers { trackedModifiers }

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
    let interaction: WindowsViewerInteraction

    var body: some View {
        Text(L("Video is available on Windows only."))
    }
}

#endif
