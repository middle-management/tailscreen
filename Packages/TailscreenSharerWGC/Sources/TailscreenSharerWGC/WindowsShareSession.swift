import Foundation
import SendInputKit
import TailscaleKit
import TailscreenProtocol
import TailscreenSharer
import WGCCaptureKit

/// Runs a share on Windows: the system capture picker, then the portable
/// `TailscaleScreenShareServer` driven by `WGCCaptureEncoder`.
///
/// A package type rather than an app file for two reasons. The first is that
/// this half must not touch the UI thread. The sign-in freeze earlier in
/// this port was exactly that mistake — a `@MainActor`-isolated async method
/// whose non-suspending body ran tsnet bring-up on the UI thread — and a
/// screen-share server brings up its own tsnet node the same way. So the
/// controller is NOT `@MainActor`; it publishes back through a callback the
/// caller hops for itself.
///
/// The picker is the deliberate exception. It is modal system UI that needs an
/// owner window and a message pump, so `pick` is called from the main thread
/// (the shim pumps while it waits) and nothing else is.
///
/// The second reason is the package's: nothing here imports a UI toolkit, so
/// Linux CI typechecks it. That matters most for exactly the concurrency
/// reasoning above, which is the part a Windows-only build would let through
/// unread until someone ran it.
///
/// Remote control is offered only when the caller can say WHERE the shared
/// content is on screen (`controlRegion`). A WGC `GraphicsCaptureItem` does
/// not expose its HMONITOR or HWND, so a picker-chosen target has no known
/// geometry and normalized coordinates cannot be mapped onto it — and a click
/// landing somewhere the viewer did not aim it is worse than a click that does
/// not happen. Without a region no injector is supplied, the server withholds
/// `ScreenShareCaps.remoteControl`, and viewers hide Request Control rather
/// than sending requests this host cannot serve. That conditional capability
/// is what the portable server gained when it stopped being macOS-only, and it
/// is what makes an incomplete platform honest rather than broken.
public final class WindowsShareSession: @unchecked Sendable {
    /// What the UI needs to render, pushed on every change.
    public struct Status: Sendable {
        public var isSharing = false
        /// The picker's own name for the target — "Screen 1", a window title.
        public var target = ""
        public var viewerCount = 0
        public var message = ""
        /// Viewers asking for remote control, awaiting an answer.
        ///
        /// The server surfaces these and does nothing else with them: a grant
        /// is a decision only the person at the keyboard can make. The Windows
        /// app had an injector, advertised the capability and then had nowhere
        /// to show the request — so a viewer pressed Request Control and
        /// nothing happened at either end.
        public var controlRequests: [ControlRequestInfo] = []
        /// Who currently holds control, if anyone.
        public var controlGrantedTo: String?
        /// Live capture timings, so "it's slow" can be answered with which
        /// stage rather than a guess.
        public var timings: CaptureTimings?

        public init() {}
    }

    /// Called off the main actor. The caller hops.
    public var onStatus: (@Sendable (Status) -> Void)?

    public init() {}

    private let lock = NSLock()
    private var server: TailscaleScreenShareServer?
    private var status = Status()

    /// Whether this machine can capture at all — checked before any UI is
    /// offered, so an unsupported Windows build is a sentence rather than a
    /// share that fails halfway.
    public var isSupported: Bool { WGC.isSupported }

    /// Show the capture picker. **Main thread only** (see the type comment).
    ///
    /// - Returns: the chosen target, or nil if the user dismissed the picker —
    ///   which is a decision, not an error, and must not raise an alert.
    @MainActor
    public func pickTarget() throws -> WGC.CaptureItem? {
        do {
            return try WGC.CaptureItem.pick(ownerWindow: nil)
        } catch WGC.Error.cancelled {
            return nil
        }
    }

    /// Bring up the sharer's tsnet node and start capturing `item`.
    ///
    /// `nonisolated` and `async`: called from a `Task` on the main actor, it
    /// runs on the global executor, so the node bring-up inside `start` never
    /// occupies the UI thread.
    /// Remote control is enabled automatically when the picked target's
    /// screen rect can be resolved — see `resolveControlRegion`. It cannot
    /// always be, and the reason lands in the published status rather than
    /// being swallowed.
    /// - Parameter existingNode: the app's already-signed-in tsnet node.
    ///   **Supply it.** Without one the server brings up its own, which needs
    ///   its own state directory — and a state directory holds a machine key,
    ///   so that is a second machine, needing a second interactive browser
    ///   login the user is never prompted for. The share then waits at that
    ///   login forever and never appears on anyone's tailnet. Sharing the
    ///   node is also what gives the app ONE identity, as the macOS app has.
    public func beginSharing(
        item: WGC.CaptureItem,
        hostname: String,
        statePath: String,
        quality: QualitySettings,
        existingNode: TailscaleNode? = nil
    ) async throws {
        // A capture FACTORY, not an instance, because the server respawns the
        // backend to restart capture. Closing over the item is what makes a
        // restart re-target the same window without asking the user again —
        // the equivalent of the macOS helper re-resolving its cached selection,
        // which a `GraphicsCaptureItem` cannot be turned back into.
        // Resolve WHERE the target is before building the server: whether an
        // injector exists at all is what decides the advertised
        // `.remoteControl` capability, and that is fixed for the session.
        let region = Self.resolveControlRegion(for: item)
        let controlNote: String
        switch region {
        case .success:
            controlNote = ""
        case .failure(let reason):
            controlNote = "Remote control is off — \(reason)"
        }

        // A resolved region means remote control is offered; an unresolved one
        // means no injector, so the server withholds `.remoteControl` and
        // viewers hide Request Control rather than sending requests that would
        // land in the wrong place.
        var injector: WindowsInputInjector?
        if case .success(let resolved) = region {
            injector = WindowsInputInjector(regionProvider: { resolved })
        }

        // The timings hook is on the concrete backend rather than the
        // `CaptureEncoding` seam, so it is attached inside the factory — which
        // also means a restart's fresh backend keeps reporting.
        let onTimings: @Sendable (CaptureTimings) -> Void = { [weak self] timings in
            self?.update { $0.timings = timings }
        }
        let newServer = TailscaleScreenShareServer(
            captureFactory: {
                let encoder = WGCCaptureEncoder(item: item)
                encoder.onTimings = onTimings
                return encoder
            },
            inputInjector: injector,
            // No overlay window on Windows, so viewer annotations would be
            // drawn confidently at a sharer that renders nothing. Withholding
            // the capability disables the viewer's drawing tools instead —
            // which is why the Mac's strokes were never appearing here.
            rendersAnnotations: false
        )
        let name = item.displayName

        newServer.onViewersChanged = { [weak self] viewers in
            self?.update { $0.viewerCount = viewers.count }
        }
        newServer.onControlRequestsChanged = { [weak self] requests in
            self?.update { $0.controlRequests = requests }
        }
        newServer.onControlGrantChanged = { [weak self] _, grant in
            self?.update { $0.controlGrantedTo = grant?.hostname ?? grant?.viewerIP }
        }
        newServer.onCaptureStopped = { [weak self] error in
            self?.update {
                $0.isSharing = false
                $0.viewerCount = 0
                $0.message = error.map { "Sharing stopped: \($0)" } ?? ""
            }
        }

        lock.withLock { server = newServer }
        update {
            $0.target = name
            $0.message = "Starting…"
        }

        // A display target with no ID: on Windows the item IS the selection,
        // and the backend was constructed with it. The kind still matters —
        // the encoder rejects `.application`, which one item cannot express.
        let selection = PickerSelection(
            kind: .display, displayID: nil, windowID: nil, bundleIDs: [])
        let selectionData = try JSONEncoder().encode(selection)

        // `TAILSCREEN_TS_CONTROL_URL` is honoured the way the rest of the
        // repo's e2e tooling honours it, but by OMITTING the argument when
        // unset rather than spelling out a default — that keeps
        // `kDefaultControlURL`, and therefore a whole TailscaleKit dependency,
        // out of the app target for the sake of one constant.
        let controlURL = ProcessInfo.processInfo.environment["TAILSCREEN_TS_CONTROL_URL"]
        let authKey = ProcessInfo.processInfo.environment["TAILSCREEN_TS_AUTHKEY"]
        do {
            if let controlURL {
                try await newServer.start(
                    hostname: hostname, authKey: authKey, path: statePath,
                    controlURL: controlURL, filterData: selectionData, quality: quality,
                    existingNode: existingNode)
            } else {
                try await newServer.start(
                    hostname: hostname, authKey: authKey, path: statePath,
                    filterData: selectionData, quality: quality,
                    existingNode: existingNode)
            }
        } catch {
            lock.withLock { server = nil }
            update {
                $0.isSharing = false
                $0.message = ""
            }
            throw error
        }

        update {
            $0.isSharing = true
            $0.message = controlNote
        }
    }

    /// Answer a pending remote-control request.
    ///
    /// Returns false when the grant was refused by the platform — which on
    /// Windows means the injector is absent (an unresolvable capture region),
    /// since UIPI has no permission to ask for.
    @discardableResult
    public func grantControl(to requestID: UUID) -> Bool {
        let server = lock.withLock { self.server }
        return server?.grantControl(toConnectionID: requestID) ?? false
    }

    public func declineControl(_ requestID: UUID) {
        let server = lock.withLock { self.server }
        server?.declineControlRequest(connectionID: requestID)
    }

    /// Take control back. The injector's revoke seal drops anything already
    /// queued and releases a button held mid-drag.
    public func revokeControl() {
        let server = lock.withLock { self.server }
        server?.revokeControl(reason: "the sharer took control back")
    }

    public func stopSharing() async {
        let running = lock.withLock {
            let value = server
            server = nil
            return value
        }
        guard let running else { return }
        await running.stop()
        update {
            $0.isSharing = false
            $0.viewerCount = 0
            $0.message = ""
        }
    }

    /// Where the picked target sits on screen, or why that is unknowable.
    ///
    /// The item carries no HMONITOR, so its SIZE is matched against the
    /// enumerated monitors — the decision itself is `WindowsCaptureRegion` in
    /// TailscreenProtocol, where Linux CI tests the cases that matter,
    /// especially the two-identical-monitors one that must decline rather than
    /// guess.
    static func resolveControlRegion(
        for item: WGC.CaptureItem
    ) -> Result<SendInputInjector.Region, WindowsCaptureRegion.Failure> {
        let size = item.size
        return WindowsCaptureRegion.resolve(
            itemWidth: size.width, itemHeight: size.height,
            monitors: SendInputInjector.monitors())
    }

    /// Mutate the published status under the lock and publish the result.
    ///
    /// The callback fires OUTSIDE the lock: it hops to the main actor, and
    /// holding a lock across that hand-off is how a UI callback ends up
    /// deadlocking against a capture thread.
    private func update(_ body: (inout Status) -> Void) {
        let snapshot: Status = lock.withLock {
            body(&status)
            return status
        }
        onStatus?(snapshot)
    }
}
