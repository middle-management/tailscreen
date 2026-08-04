import Foundation
import SwiftCrossUI
import TailscreenL10n

// Targeted imports, the same dodge `TailscreenWindowsApp.swift` documents:
// pulling all of TailscreenProtocol brings its `Published` / `ObservableObject`
// portability shims, which are DIFFERENT protocols from the identically-named
// ones SwiftCrossUI observes, and the ambiguity is a wall of errors rather than
// one.
import struct TailscreenProtocol.Annotation
import enum TailscreenProtocol.AnnotationOp
import class TailscreenProtocol.AnnotationStore
import enum TailscreenProtocol.AnnotationTool
import enum TailscreenProtocol.InputEvent
import struct TailscreenProtocol.ScreenShareCaps
import enum TailscreenProtocol.ViewerZoomMath
import struct TailscreenProtocol.ViewerZoomState
import class TailscreenViewerTsnet.ViewerBackChannel

/// The viewer's interactive state: what the sharer said it supports, where
/// remote control is in its lifecycle, which annotation tool is armed, and the
/// zoom/pan transform.
///
/// The Windows counterpart of the GTK viewer's `ViewerUIState` + `ViewerControls`
/// + `InputForwarder`, folded into one type because there is less of it here:
/// the shared `TailscreenHubUI` already owns the toolbar and the control bar,
/// `ViewerZoomMath` owns the geometry, `AnnotationStore` owns the canvas, and
/// `ViewerPointerMapping` owns the letterbox arithmetic. What is left is the
/// state machine and the ordering discipline, which is what this file is.
///
/// **No WinUI in here on purpose.** Everything below compiles on Linux, which
/// is the point: this is the layer where the mistakes are, and the Windows
/// runner takes forty minutes to find one. `WinUIVideoView` is the only file
/// that may not compile here, and it is deliberately kept to event plumbing.
@MainActor
final class WindowsViewerInteraction: ObservableObject {
    // MARK: Capabilities

    /// Whether the sharer advertised `ScreenShareCaps.remoteControl` (bit 3).
    ///
    /// Default **false**, and the Request Control affordance is hidden until it
    /// arrives. A viewer that offers control to a sharer that cannot inject
    /// sends `.controlRequest` messages into a void — the sharer drops them
    /// silently and the viewer waits forever on a request nobody will ever see.
    @Published private(set) var remoteControlAvailable = false

    /// Whether the sharer advertised `ScreenShareCaps.annotations` (bit 4).
    ///
    /// Same shape, same reason: a viewer drawing strokes at a sharer with no
    /// overlay draws them for other *viewers* only, which with one viewer — the
    /// common case — means drawing does nothing at all and looks like a bug in
    /// this app.
    @Published private(set) var annotationsAvailable = false

    // MARK: Remote control

    enum ControlState: Equatable {
        case idle
        case requested
        case active
        case revoked(reason: String)
    }

    @Published private(set) var controlState: ControlState = .idle

    /// Label for the shared `RemoteControlBar`'s single button.
    var controlButtonLabel: String {
        switch controlState {
        case .idle, .revoked: return L("Request Control")
        case .requested: return L("Requesting…")
        case .active: return L("Release Control")
        }
    }

    /// The decline reason, when there is one to show. Empty reasons are nil so
    /// the bar does not render "Control declined: " with nothing after it — a
    /// revoke carries a reason only sometimes.
    var controlDeclinedReason: String? {
        if case .revoked(let reason) = controlState, !reason.isEmpty { return reason }
        return nil
    }

    /// Whether pointer and key events should be forwarded to the sharer.
    ///
    /// Drawing wins over controlling when both are possible: with a tool armed
    /// a drag is a stroke, not a click. That is the same precedence the GTK
    /// viewer uses, and it has to be *somewhere* — a drag cannot be both.
    var forwardsInput: Bool { controlState == .active && activeTool == nil }

    // MARK: Annotations

    /// The armed tool, or nil when drawing is off.
    @Published private(set) var activeTool: AnnotationTool?

    /// The canvas itself — shared with the GTK viewer, and the thing
    /// `WinUIVideoView` rasterizes into each frame.
    let annotations = AnnotationStore()

    /// Whether the stats HUD is shown.

    // MARK: Zoom

    /// Content zoom + pan, in the portable `ViewerZoomMath` space macOS and the
    /// GTK viewer already use. Its geometry is in **viewport points** against
    /// a `fit` rect, so every mutator below takes the pane's current bounds —
    /// a stale fit is what makes the first gesture after a resize jump.
    @Published private(set) var zoomState = ViewerZoomState()

    var isZoomed: Bool { zoomState.isZoomedIn }

    // MARK: Wiring

    /// The live back-channel, rebound per session. Nil between sessions, which
    /// is what makes every send below a no-op rather than a crash after a
    /// disconnect.
    private var channel: ViewerBackChannel?

    /// Serialized outbound sends.
    ///
    /// One stream drained by one consumer, so add/undo/clear and pointer
    /// events reach the sharer in the order they happened. Without it each send
    /// is its own `Task` and the runtime is free to reorder them — which turns
    /// "undo" arriving before the stroke it undoes into a stroke that never
    /// goes away. Same discipline as the GTK viewer's `AnnotationForwarder`.
    private let outbound: AsyncStream<Outbound>
    private let outboundContinuation: AsyncStream<Outbound>.Continuation
    private var drainStarted = false

    private enum Outbound {
        case annotation(AnnotationOp)
        case input(InputEvent)
        case requestControl
        case releaseControl
    }

    init() {
        var continuation: AsyncStream<Outbound>.Continuation!
        outbound = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        outboundContinuation = continuation
        annotations.onLocalOp = { [weak self] op in
            MainActor.assumeIsolated { self?.send(.annotation(op)) }
        }
    }

    /// Start a fresh session: clear last session's canvas and state, and bind
    /// the new channel.
    ///
    /// Capabilities are reset to false rather than carried over. A sharer that
    /// supported control last time may not this time, and inheriting the answer
    /// would offer an affordance nothing will serve — the exact failure the
    /// bits exist to prevent.
    func beginSession(channel: ViewerBackChannel) {
        self.channel = channel
        remoteControlAvailable = false
        annotationsAvailable = false
        controlState = .idle
        activeTool = nil
        annotations.resetForNewSession()
        resetZoom()
        startDraining()
    }

    func endSession() {
        channel = nil
        controlState = .idle
        activeTool = nil
        remoteControlAvailable = false
        annotationsAvailable = false
        annotations.resetForNewSession()
        resetZoom()
    }

    /// Apply the sharer's advertised capabilities from the HELLO_ACK.
    func setCaps(_ caps: ScreenShareCaps) {
        remoteControlAvailable = caps.contains(.remoteControl)
        annotationsAvailable = caps.contains(.annotations)
        // A sharer that does not render annotations must not leave a tool armed
        // from a previous session, or the viewer draws strokes reaching nobody.
        if !annotationsAvailable { activeTool = nil }
    }

    // MARK: Inbound (from the back-channel, off the main actor)

    /// Handlers for `transport.run(backChannelHandlers:)`. Each hops to the
    /// main actor — they fire on the back-channel's own task.
    func backChannelHandlers() -> ViewerBackChannel.Handlers {
        ViewerBackChannel.Handlers(
            onAnnotation: { [weak self] op in
                Task { @MainActor in self?.annotations.apply(op) }
            },
            onControlGranted: { [weak self] in
                Task { @MainActor in self?.controlState = .active }
            },
            onControlRevoked: { [weak self] reason in
                Task { @MainActor in self?.controlState = .revoked(reason: reason) }
            })
    }

    // MARK: Outbound

    /// Toggle remote control: request it, or release it if held.
    ///
    /// A `.requested` state is NOT re-requestable — pressing the button again
    /// while waiting would queue a second request the sharer sees as a separate
    /// prompt.
    func toggleControl() {
        guard remoteControlAvailable else { return }
        switch controlState {
        case .idle, .revoked:
            controlState = .requested
            send(.requestControl)
        case .active:
            // Optimistic: the sharer's `.controlRevoked` will confirm, but the
            // local gate must close NOW or a stray pointer move between the
            // release and its acknowledgement still reaches the sharer's
            // desktop.
            controlState = .idle
            send(.releaseControl)
        case .requested:
            break
        }
    }

    /// Arm a drawing tool, or disarm it if it was already armed.
    ///
    /// Toggling off matters: with no tool armed a drag zooms or drives remote
    /// control, and a toolbar that can only ever *switch* tools has no way back
    /// to that.
    func selectTool(_ tool: AnnotationTool) {
        guard annotationsAvailable else { return }
        activeTool = (activeTool == tool) ? nil : tool
        annotations.mode = activeTool.map { .drawing($0) } ?? .off
    }

    func undoAnnotation() { annotations.undo() }
    func clearAnnotations() { annotations.clearAll() }

    /// Forward one input event, if the grant gate is open.
    ///
    /// The gate is checked HERE rather than at the call site so there is one
    /// place that can be wrong. The sharer gates again on its own side — this
    /// is not the security boundary, it is what stops the viewer sending
    /// pointer traffic nobody wants.
    func forward(_ event: InputEvent) {
        guard forwardsInput else { return }
        send(.input(event))
    }

    // MARK: Zoom

    /// Zoom about a viewport point by a multiplicative step.
    ///
    /// `fit` is the aspect-fit rect the video occupies inside the pane, and it
    /// is passed per gesture rather than stored: the pane resizes, and
    /// anchoring against a stale rect makes the video jump away from the cursor
    /// on the first gesture after a resize. `ViewerZoomMath` re-clamps the
    /// incoming offset against it for exactly that reason.
    func zoom(by delta: CGFloat, anchor: CGPoint, fit: CGRect) {
        zoomState = ViewerZoomMath.zoomed(
            state: zoomState, by: delta, anchor: anchor, fit: fit)
    }

    /// Pan the content by a viewport-point delta. No-ops at fit, where the
    /// offset clamp collapses to zero.
    func pan(by delta: CGSize, fit: CGRect) {
        zoomState = ViewerZoomMath.panned(state: zoomState, by: delta, fit: fit)
    }

    /// Double-click: zoomed in → back to fit, at fit → 2× at the click.
    func smartMagnify(anchor: CGPoint, fit: CGRect) {
        zoomState = ViewerZoomMath.smartMagnifyToggled(
            state: zoomState, anchor: anchor, fit: fit)
    }

    func resetZoom() {
        zoomState = ViewerZoomState()
    }

    // MARK: Send plumbing

    private func send(_ item: Outbound) {
        outboundContinuation.yield(item)
    }

    private func startDraining() {
        guard !drainStarted else { return }
        drainStarted = true
        let stream = outbound
        Task { [weak self] in
            for await item in stream {
                // No `await`: the Task inherits this @MainActor context, so
                // the read is already isolated — and the compiler flags a
                // needless await as a warning, which `--strict` turns red.
                guard let channel = self?.channel else { continue }
                switch item {
                case .annotation(let op): await channel.sendAnnotation(op)
                case .input(let event): await channel.sendInputEvent(event)
                case .requestControl: await channel.requestControl()
                case .releaseControl: await channel.releaseControl()
                }
            }
        }
    }
}
