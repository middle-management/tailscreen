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
import struct TailscreenProtocol.OpenLinkPayload
import struct TailscreenProtocol.ScreenShareCaps
import enum TailscreenProtocol.ViewerZoomMath
import struct TailscreenProtocol.ViewerZoomState
import class TailscreenViewerTsnet.ViewerBackChannel

/// The viewer's interactive state: what the sharer said it supports, where
/// remote control is in its lifecycle, which annotation tool is armed, and
/// the zoom/pan transform.
///
/// The Windows counterpart of the GTK viewer's `ViewerUIState` +
/// `ViewerControls` + `InputForwarder`, folded into one type: `TailscreenHubUI`
/// owns the toolbar/control bar, `ViewerZoomMath` the geometry, `AnnotationStore`
/// the canvas. What's left is the state machine and ordering discipline.
///
/// No WinUI in here on purpose — everything compiles on Linux, where mistakes
/// are cheap to find. `WinUIVideoView` is the only file kept to event plumbing.
@MainActor
final class WindowsViewerInteraction: ObservableObject {
    // MARK: Capabilities

    /// Whether the sharer advertised `ScreenShareCaps.remoteControl` (bit 3).
    /// Default false: the Request Control affordance is hidden until it
    /// arrives, since a sharer that can't inject would drop the request
    /// silently and the viewer would wait forever.
    @Published private(set) var remoteControlAvailable = false

    /// Whether the sharer advertised `ScreenShareCaps.annotations` (bit 4).
    /// Same shape: drawing at a sharer with no overlay would only reach
    /// other viewers, looking like a bug with one viewer connected.
    @Published private(set) var annotationsAvailable = false

    /// Whether the sharer advertised `ScreenShareCaps.openLink` (bit 6).
    /// Same shape as the other two: hides "Open Link on Sharer…" rather than
    /// offer a send that reaches a sharer that never prompts anyone.
    @Published private(set) var openLinkAvailable = false

    // MARK: Remote control

    enum ControlState: Equatable {
        case idle
        case requested
        case active
        case revoked(reason: String)
    }

    @Published private(set) var controlState: ControlState = .idle

    /// Label for the shared `RemoteControlBar`'s single button. Says what
    /// pressing DOES, not what's happening — this bar has no tooltip to hang
    /// "click to cancel" off of.
    var controlButtonLabel: String {
        switch controlState {
        case .idle, .revoked: return L("Request Control")
        case .requested: return L("Cancel Request")
        case .active: return L("Release Control")
        }
    }

    /// The decline reason, when there is one to show. Empty reasons are nil
    /// so the bar doesn't render "Control declined: " with nothing after it.
    var controlDeclinedReason: String? {
        if case .revoked(let reason) = controlState, !reason.isEmpty { return reason }
        return nil
    }

    /// Whether pointer and key events should be forwarded to the sharer.
    /// Drawing wins over controlling: with a tool armed a drag is a stroke,
    /// not a click. Same precedence as the GTK viewer.
    var forwardsInput: Bool { controlState == .active && activeTool == nil }

    /// True while this viewer holds the grant — drives the shared bar's
    /// "you are controlling" state line.
    var isControlling: Bool { controlState == .active }

    // MARK: Annotations

    /// The armed tool, or nil when drawing is off.
    @Published private(set) var activeTool: AnnotationTool?

    /// The canvas itself — shared with the GTK viewer, and the thing
    /// `WinUIVideoView` rasterizes into each frame.
    let annotations = AnnotationStore()

    /// The color this viewer draws in — a published MIRROR of
    /// `annotations.color`, which stays the source of truth. Published so the
    /// toolbar swatch re-renders on pick.
    @Published private(set) var inkColor: Annotation.RGBA

    /// Pick a drawing color. Sets the canvas — per-stroke color rides the
    /// annotation wire, so no protocol change is needed — and the mirror above.
    func selectColor(_ color: Annotation.RGBA) {
        annotations.color = color
        inkColor = color
    }

    // MARK: Zoom

    /// Content zoom + pan, in the portable `ViewerZoomMath` space macOS and
    /// the GTK viewer use. Geometry is in viewport points against a `fit`
    /// rect, so every mutator below takes the pane's current bounds — a
    /// stale fit makes the first gesture after a resize jump.
    @Published private(set) var zoomState = ViewerZoomState()

    var isZoomed: Bool { zoomState.isZoomedIn }

    // MARK: Wiring

    /// The live back-channel, rebound per session. Nil between sessions, so
    /// every send below is a no-op rather than a crash after a disconnect.
    private var channel: ViewerBackChannel?

    /// Serialized outbound sends: one stream drained by one consumer, so
    /// add/undo/clear and pointer events reach the sharer in order. Same
    /// discipline as the GTK viewer's `AnnotationForwarder`.
    private let outbound: AsyncStream<Outbound>
    private let outboundContinuation: AsyncStream<Outbound>.Continuation
    private var drainStarted = false

    private enum Outbound {
        case annotation(AnnotationOp)
        case input(InputEvent)
        case requestControl
        case releaseControl
        case openLink(String)
    }

    init() {
        inkColor = annotations.color
        var continuation: AsyncStream<Outbound>.Continuation!
        outbound = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        outboundContinuation = continuation
        annotations.onLocalOp = { [weak self] op in
            MainActor.assumeIsolated { self?.send(.annotation(op)) }
        }
    }

    /// Start a fresh session: clear last session's canvas and state, and bind
    /// the new channel. Capabilities reset to false rather than carrying
    /// over — a sharer that supported control last time may not this time.
    func beginSession(channel: ViewerBackChannel) {
        self.channel = channel
        remoteControlAvailable = false
        annotationsAvailable = false
        openLinkAvailable = false
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
        openLinkAvailable = false
        annotations.resetForNewSession()
        resetZoom()
    }

    /// Apply the sharer's advertised capabilities from the HELLO_ACK.
    func setCaps(_ caps: ScreenShareCaps) {
        remoteControlAvailable = caps.contains(.remoteControl)
        annotationsAvailable = caps.contains(.annotations)
        openLinkAvailable = caps.contains(.openLink)
        // A sharer with no annotations render must not leave a tool armed.
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
                Task { @MainActor in
                    guard let self else { return }
                    // Only enter control if still asking: a cancel can cross
                    // a grant on the wire, and forcing someone who withdrew
                    // into driving another machine is the worst outcome —
                    // hand it straight back, same as macOS's `onControlGranted`.
                    guard self.controlState == .requested else {
                        self.send(.releaseControl)
                        return
                    }
                    self.controlState = .active
                }
            },
            onControlRevoked: { [weak self] reason in
                Task { @MainActor in self?.controlState = .revoked(reason: reason) }
            })
    }

    // MARK: Outbound

    /// Toggle remote control: request it, cancel a pending request, or
    /// release a held grant. A `.requested` state is NOT re-requestable but
    /// IS cancellable — otherwise a viewer waiting on the sharer's decision
    /// has no way to withdraw.
    ///
    /// Cancelling reuses the same `.controlReleased` (0x0A) the release path
    /// sends — the sharer's listener treats it as "I'm done" either way.
    func toggleControl() {
        guard remoteControlAvailable else { return }
        switch controlState {
        case .idle, .revoked:
            controlState = .requested
            send(.requestControl)
        case .requested, .active:
            // Optimistic: the local gate must close NOW, before the sharer's
            // `.controlRevoked` confirms, or a stray pointer move still
            // reaches the sharer's desktop.
            controlState = .idle
            send(.releaseControl)
        }
    }

    /// Arm a drawing tool, or disarm it if it was already armed. Toggling off
    /// matters: with no tool armed a drag zooms or drives remote control.
    func selectTool(_ tool: AnnotationTool) {
        guard annotationsAvailable else { return }
        activeTool = (activeTool == tool) ? nil : tool
        annotations.mode = activeTool.map { .drawing($0) } ?? .off
    }

    func undoAnnotation() { annotations.undo() }
    func clearAnnotations() { annotations.clearAll() }

    /// Forward one input event, if the grant gate is open. Checked HERE, not
    /// at the call site, so there's one place that can be wrong — the
    /// sharer's own gate is the actual security boundary.
    func forward(_ event: InputEvent) {
        guard forwardsInput else { return }
        send(.input(event))
    }

    /// Offer `text` to the sharer as a link to open, after trimming and
    /// validating it. Validated HERE rather than in the composer view, so
    /// there is one place that can be wrong about what the sharer would
    /// accept — the sharer re-validates on arrival regardless.
    /// - Returns: true if it was accepted and sent; false leaves `text` in
    ///   the composer for the caller to show as unsent.
    @discardableResult
    func sendLink(_ text: String) -> Bool {
        guard openLinkAvailable else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OpenLinkPayload.isAcceptable(trimmed) else { return false }
        send(.openLink(trimmed))
        return true
    }

    // MARK: Zoom

    /// Zoom about a viewport point by a multiplicative step. `fit` is passed
    /// per gesture rather than stored, since a stale rect would make the
    /// video jump away from the cursor on the first gesture after a resize.
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
                // No `await`: the Task inherits this @MainActor context.
                guard let channel = self?.channel else { continue }
                switch item {
                case .annotation(let op): await channel.sendAnnotation(op)
                case .input(let event): await channel.sendInputEvent(event)
                case .requestControl: await channel.requestControl()
                case .releaseControl: await channel.releaseControl()
                case .openLink(let url): await channel.sendOpenLink(url)
                }
            }
        }
    }
}
