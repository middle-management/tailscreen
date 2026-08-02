import CPortalCapture
import Foundation

/// Screen capture through `org.freedesktop.portal.ScreenCast` and PipeWire —
/// the Wayland-capable capture path for the Linux sharer.
///
/// This is the capture half of a Linux `CaptureEncoding` backend, the same
/// role `X11ScreenCapture` plays for X11 and `WGCCapture` plays on Windows.
/// What it adds over the X11 path is everything the X11 path structurally
/// cannot do: native Wayland surfaces, a single window, a single application.
///
/// **It hands back BGRA and converts nothing.** The repo's portable
/// `BGRAToI420` (TailscreenProtocol) owns colour, and the `CaptureEncoding`
/// conformance that will consume this is where the two meet — the identical
/// split `WGCCaptureKit` → `TailscreenSharerWGC` already uses on Windows.
/// Writing a third BGRA→I420 here would be a third implementation to keep in
/// step with the viewer's YUV shader, and getting that wrong does not fail: it
/// washes out or crushes every frame.
///
/// **There is no headless path and there never will be.** Every share starts
/// with a dialog the compositor draws and a person clicks. That is not a
/// limitation to route around — it is the user's control over their own
/// screen, and this package contains nothing that tries to.
public enum PortalCapture {
    /// libpipewire's version, and the reason `portal-probe` exists: a SwiftPM
    /// library target is compiled but never linked, so a missing
    /// `-lpipewire-0.3` stays invisible until something downstream links it.
    public static var pipewireVersion: String {
        String(cString: ts_pwcap_library_version())
    }
}

// MARK: - Session

/// A live `org.freedesktop.portal.ScreenCast` session.
///
/// Not `Sendable`: it owns a private D-Bus connection that libdbus expects to
/// be driven from one thread, and `negotiate` blocks that thread for as long as
/// the consent dialog is on screen. Hosts drive it off their UI thread.
public final class PortalSession {
    /// What went wrong, split finely enough that a sharer UI can say the right
    /// thing. In particular ``cancelled`` is **not** a failure — a person
    /// declining to share their screen must not produce an error dialog.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// No session bus at all: a headless machine, or a process started
        /// without `DBUS_SESSION_BUS_ADDRESS`.
        case noSessionBus(String)
        /// The bus is there; `org.freedesktop.portal.Desktop` is not.
        case portalUnavailable(String)
        /// The user dismissed the dialog.
        case cancelled
        /// The portal answered with a failure of its own.
        case portalError(String)
        /// No `Response` inside the deadline — which, on a real desktop,
        /// usually means the dialog is still sitting on screen.
        case timedOut(String)
        /// A reply we could not parse. A portal-version mismatch, or a bug
        /// here.
        case malformedReply(String)
        /// Consent was given but nothing came back to capture.
        case noStreams(String)
        case invalidArguments

        public var description: String {
            switch self {
            case .noSessionBus(let detail): return "no D-Bus session bus: \(detail)"
            case .portalUnavailable(let detail): return "no desktop portal: \(detail)"
            case .cancelled: return "the screen-sharing request was declined"
            case .portalError(let detail): return "the desktop portal refused: \(detail)"
            case .timedOut(let detail): return "the desktop portal did not answer: \(detail)"
            case .malformedReply(let detail): return "unexpected portal reply: \(detail)"
            case .noStreams(let detail): return "the portal returned nothing to capture: \(detail)"
            case .invalidArguments: return "invalid capture request"
            }
        }

        static func from(code: Int32, detail: String) -> Failure {
            switch code {
            case TS_PORTAL_ERR_NO_BUS: return .noSessionBus(detail)
            case TS_PORTAL_ERR_NO_PORTAL: return .portalUnavailable(detail)
            case TS_PORTAL_ERR_CANCELLED: return .cancelled
            case TS_PORTAL_ERR_TIMEOUT: return .timedOut(detail)
            case TS_PORTAL_ERR_PROTOCOL: return .malformedReply(detail)
            case TS_PORTAL_ERR_NO_STREAMS: return .noStreams(detail)
            case TS_PORTAL_ERR_ARGS: return .invalidArguments
            default: return .portalError(detail)
            }
        }
    }

    /// What the user may be offered in the portal's picker.
    public struct SourceTypes: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let monitor = SourceTypes(rawValue: 1)
        public static let window = SourceTypes(rawValue: 2)
        public static let virtual = SourceTypes(rawValue: 4)
    }

    /// How the pointer is delivered.
    ///
    /// ``embedded`` is what a screen share wants: the compositor composites the
    /// pointer into the frames. ``metadata`` delivers position out-of-band and
    /// would need a compositing step this package does not have — asking for it
    /// yields frames with no visible cursor, which looks like a bug rather than
    /// a choice.
    public enum CursorMode: UInt32, Sendable {
        case hidden = 1
        case embedded = 2
        case metadata = 4
    }

    /// Whether the portal should remember this grant.
    ///
    /// The portal's own consent memory, offered because the user ticked its
    /// box. It is not a way to skip the dialog and there is no such way.
    public enum PersistMode: UInt32, Sendable {
        case none = 0
        case whileRunning = 1
        case untilRevoked = 2
    }

    /// One stream the portal handed back.
    public struct Stream: Sendable, Equatable {
        public let nodeID: UInt32
        /// The portal's reported size, when it reported one. The negotiated
        /// PipeWire format is the authority; this is for logging before the
        /// stream opens.
        public let width: Int?
        public let height: Int?
        public let sourceTypes: SourceTypes
    }

    private let handle: OpaquePointer

    public init() throws {
        guard let handle = ts_portal_new() else { throw Failure.invalidArguments }
        self.handle = handle
    }

    deinit {
        // Synchronous teardown, no Task capturing self — the repo's rule, and
        // here it also closes the portal session, which is what makes the
        // compositor drop its "your screen is being shared" indicator.
        ts_portal_free(handle)
    }

    private var lastError: String { String(cString: ts_portal_last_error(handle)) }

    /// Connect to the session bus and check a portal is present, **without**
    /// putting anything on anybody's screen.
    ///
    /// This is the honest way for a host to answer "can this machine share?" —
    /// a capability check that raises a consent dialog is not a capability
    /// check.
    public func connect() throws {
        let rc = ts_portal_connect(handle)
        guard rc == TS_PORTAL_OK else { throw Failure.from(code: rc, detail: lastError) }
    }

    /// What the portal advertises it can offer. Empty means it did not say —
    /// the properties are versioned, and an older portal simply lacks them, so
    /// an empty set must be read as "unknown", never as "nothing".
    public var availableSourceTypes: SourceTypes {
        SourceTypes(rawValue: ts_portal_available_source_types(handle))
    }

    /// See ``availableSourceTypes`` — empty means unknown, not none.
    public var availableCursorModes: [CursorMode] {
        let raw = ts_portal_available_cursor_modes(handle)
        return [.hidden, .embedded, .metadata].filter { raw & $0.rawValue != 0 }
    }

    /// Run CreateSession → SelectSources → Start.
    ///
    /// **This raises the consent dialog and blocks the calling thread** until
    /// the user answers or `timeout` elapses. `timeout` is a human-scale
    /// budget: anything under about 30 seconds will time out on a real desktop
    /// more often than it succeeds.
    public func negotiate(
        sources: SourceTypes = [.monitor, .window],
        cursor: CursorMode = .embedded,
        persist: PersistMode = .none,
        restoreToken: String? = nil,
        timeout: Duration = .seconds(120)
    ) throws -> [Stream] {
        let milliseconds = Int32(
            max(1, min(Int(Int32.max), Int(timeout.components.seconds * 1000))))

        var streams = [ts_portal_stream_t](repeating: ts_portal_stream_t(), count: 8)
        var count: Int32 = 0
        let rc: Int32 = withOptionalCString(restoreToken) { token in
            var request = ts_portal_request_t(
                source_types: sources.rawValue,
                cursor_mode: cursor.rawValue,
                multiple: 0,
                persist_mode: persist.rawValue,
                restore_token: token,
                timeout_ms: milliseconds)
            return streams.withUnsafeMutableBufferPointer { buffer in
                ts_portal_negotiate(
                    handle, &request, buffer.baseAddress, Int32(buffer.count),
                    &count)
            }
        }
        guard rc == TS_PORTAL_OK else { throw Failure.from(code: rc, detail: lastError) }

        return streams.prefix(Int(count)).map { raw in
            Stream(
                nodeID: raw.node_id,
                width: raw.width > 0 ? Int(raw.width) : nil,
                height: raw.height > 0 ? Int(raw.height) : nil,
                sourceTypes: SourceTypes(rawValue: raw.source_type))
        }
    }

    /// The portal's restore token from the last successful ``negotiate``, when
    /// one was asked for and the portal agreed to issue it. Persist it to offer
    /// the user a share that does not re-prompt — the portal still decides.
    public var restoreToken: String? {
        ts_portal_restore_token(handle).map { String(cString: $0) }
    }

    /// Open the PipeWire remote for this session.
    ///
    /// The returned descriptor is handed to ``PortalStream``, which **takes
    /// ownership** of it. Close it yourself only if you never get that far.
    public func openPipeWireFileDescriptor() throws -> Int32 {
        let fd = ts_portal_open_pipewire_fd(handle)
        guard fd >= 0 else { throw Failure.from(code: fd, detail: lastError) }
        return fd
    }

    /// End the session. Idempotent, and called for you on deinit.
    public func close() {
        ts_portal_close_session(handle)
    }

    /// The `org.freedesktop.portal.Request` object path a `Response` for
    /// `token` will arrive on, given a unique bus name.
    ///
    /// Exposed because it is the one piece of the handshake that is pure string
    /// arithmetic and the one whose failure is silent: derive it wrong and the
    /// client subscribes to a path nothing is emitted on, so every call times
    /// out with no error anywhere.
    public static func requestPath(uniqueName: String, token: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let rc = uniqueName.withCString { name in
            token.withCString { tok in
                buffer.withUnsafeMutableBufferPointer { out in
                    ts_portal_request_path(name, tok, out.baseAddress, out.count)
                }
            }
        }
        guard rc == TS_PORTAL_OK else { return nil }
        return buffer.withUnsafeBufferPointer { raw in
            raw.baseAddress.map { String(cString: $0) }
        }
    }
}

// MARK: - Stream

/// A live PipeWire capture stream, delivering packed BGRA frames.
///
/// Frames arrive on PipeWire's own thread, which is what the portable
/// `CaptureEncoding` contract already assumes ("callbacks fire on whatever
/// thread the backend produces on"). Handlers must be thread-safe.
public final class PortalStream: @unchecked Sendable {
    /// One frame. The pointer is valid **only for the duration of the call** —
    /// it is PipeWire's buffer and goes back to the producer when the handler
    /// returns. Copy or convert inside the callback; do not stash it.
    public struct Frame {
        public let bgra: UnsafePointer<UInt8>
        /// Row pitch in BYTES. Not `width * 4` in general — PipeWire producers
        /// pad rows, and reading at `width * 4` skews the image further with
        /// every row.
        public let stride: Int
        public let width: Int
        public let height: Int
    }

    public enum State: Sendable, Equatable {
        case connecting
        case streaming
        case failed(String)
        /// The producer went away — on a real desktop, usually the user
        /// clicking the compositor's own "stop sharing". A normal end to a
        /// share, deliberately distinct from ``failed`` so a host tears down
        /// quietly instead of trying to restart something that is gone.
        case ended(String)
    }

    private final class Callbacks {
        var onFrame: ((Frame) -> Void)?
        var onState: ((State) -> Void)?
    }

    private let callbacks = Callbacks()
    private let handle: OpaquePointer
    private let boxed: Unmanaged<AnyObject>

    /// - Parameter fileDescriptor: from
    ///   ``PortalSession/openPipeWireFileDescriptor()``. **Ownership passes
    ///   here**, including when this initializer throws.
    public init(
        fileDescriptor: Int32,
        nodeID: UInt32,
        onFrame: @escaping (Frame) -> Void,
        onState: @escaping (State) -> Void
    ) throws {
        callbacks.onFrame = onFrame
        callbacks.onState = onState
        let boxed = Unmanaged<AnyObject>.passRetained(callbacks)
        self.boxed = boxed

        let frameThunk:
            @convention(c) (
                UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int32, Int32, Int32
            ) -> Void = { user, bgra, stride, width, height in
                guard let user, let bgra,
                    let callbacks = Unmanaged<AnyObject>.fromOpaque(user).takeUnretainedValue()
                        as? Callbacks
                else { return }
                callbacks.onFrame?(
                    Frame(bgra: bgra, stride: Int(stride), width: Int(width), height: Int(height)))
            }
        let stateThunk:
            @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?)
                -> Void = { user, state, detail in
                    guard let user,
                        let callbacks = Unmanaged<AnyObject>.fromOpaque(user).takeUnretainedValue()
                            as? Callbacks
                    else { return }
                    let text = detail.map { String(cString: $0) } ?? ""
                    switch state {
                    case TS_PWCAP_STATE_STREAMING: callbacks.onState?(.streaming)
                    case TS_PWCAP_STATE_ERROR: callbacks.onState?(.failed(text))
                    case TS_PWCAP_STATE_ENDED: callbacks.onState?(.ended(text))
                    default: callbacks.onState?(.connecting)
                    }
                }

        guard
            let handle = ts_pwcap_open(
                fileDescriptor, nodeID, frameThunk, stateThunk, boxed.toOpaque())
        else {
            // ts_pwcap_open closed the descriptor itself — closing it here too
            // would be a double close on a number the process may have reused.
            boxed.release()
            throw PortalSession.Failure.portalError("could not open the PipeWire stream")
        }
        self.handle = handle
    }

    deinit {
        // Close first: it stops the stream's thread, which is what guarantees
        // no callback is in flight when the box is released.
        ts_pwcap_close(handle)
        boxed.release()
    }

    /// The negotiated frame size once a format has been agreed, else nil.
    /// A resized window changes it mid-stream, which is why it is a query.
    public var size: (width: Int, height: Int)? {
        var width: Int32 = 0
        var height: Int32 = 0
        guard ts_pwcap_size(handle, &width, &height) != 0 else { return nil }
        return (Int(width), Int(height))
    }

    /// Frames delivered so far — the liveness signal a `CaptureEncoding`
    /// backend feeds to the server's hung-backend watchdog.
    public var frameCount: UInt64 { ts_pwcap_frame_count(handle) }
}

// MARK: - Helpers

private func withOptionalCString<Result>(
    _ value: String?, _ body: (UnsafePointer<CChar>?) -> Result
) -> Result {
    guard let value else { return body(nil) }
    return value.withCString { body($0) }
}
