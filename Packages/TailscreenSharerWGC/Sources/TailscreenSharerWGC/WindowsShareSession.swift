import Foundation
import SendInputKit
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
    /// - Parameter controlRegion: where the shared content sits in screen
    ///   pixels, or nil when unknown. Supplying it is what enables remote
    ///   control; see the type comment for why it cannot be derived from the
    ///   capture item. Re-read on every activation, so a window that has been
    ///   moved or resized still maps correctly.
    public func beginSharing(
        item: WGC.CaptureItem,
        hostname: String,
        statePath: String,
        quality: QualitySettings,
        controlRegion: (@Sendable () -> SendInputInjector.Region?)? = nil
    ) async throws {
        // A capture FACTORY, not an instance, because the server respawns the
        // backend to restart capture. Closing over the item is what makes a
        // restart re-target the same window without asking the user again —
        // the equivalent of the macOS helper re-resolving its cached selection,
        // which a `GraphicsCaptureItem` cannot be turned back into.
        let newServer = TailscaleScreenShareServer(
            captureFactory: { WGCCaptureEncoder(item: item) },
            inputInjector: controlRegion.map { WindowsInputInjector(regionProvider: $0) }
        )
        let name = item.displayName

        newServer.onViewersChanged = { [weak self] viewers in
            self?.update { $0.viewerCount = viewers.count }
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
                    controlURL: controlURL, filterData: selectionData, quality: quality)
            } else {
                try await newServer.start(
                    hostname: hostname, authKey: authKey, path: statePath,
                    filterData: selectionData, quality: quality)
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
            $0.message = ""
        }
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
