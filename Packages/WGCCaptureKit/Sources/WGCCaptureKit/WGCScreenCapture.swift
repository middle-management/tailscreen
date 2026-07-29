import Foundation

#if os(Windows)
import CWGCCapture
#endif

/// Swift face of Windows.Graphics.Capture — the Windows analogue of
/// ScreenCaptureKit, picker and all.
///
/// Thin by design, like `WASAPI.Player`: the shim owns the WinRT lifetime and
/// this owns the Swift ergonomics — a throwing API, a typed error, and a scoped
/// frame accessor that cannot leak the mapping.
public enum WGC {
    public enum Error: Swift.Error, CustomStringConvertible {
        case invalidArgument
        /// The user dismissed the picker without choosing. Not a failure —
        /// callers should return quietly rather than show an alert.
        case cancelled
        /// The captured window closed or the display was disconnected. The
        /// macOS sharer treats the equivalent as `source-gone` and tears the
        /// share down gently rather than as an error.
        case sourceClosed
        /// This Windows build has no WGC, or policy disables it.
        case unavailable
        case busy
        case hresult(Int32)
        case unsupportedPlatform

        public var description: String {
            switch self {
            case .invalidArgument: return "invalid argument"
            case .cancelled: return "no capture source was chosen"
            case .sourceClosed: return "the shared window or display is gone"
            case .unavailable:
                return "screen capture is unavailable on this version of Windows"
            case .busy: return "a frame is already mapped"
            case .hresult(let code):
                return "capture failed (HRESULT 0x\(String(UInt32(bitPattern: code), radix: 16)))"
            case .unsupportedPlatform:
                return "Windows.Graphics.Capture is only available on Windows"
            }
        }

        static func from(code: Int32) -> Error {
            switch code {
            case -1: return .invalidArgument
            case -3: return .sourceClosed
            case -4: return .cancelled
            case -5: return .unavailable
            case -6: return .busy
            default: return .hresult(code)
            }
        }
    }

    /// Whether this machine can capture at all. Checked before any UI is shown,
    /// so a missing feature is a sentence rather than a failed share.
    public static var isSupported: Bool {
        #if os(Windows)
        return ts_wgc_is_supported() == 1
        #else
        return false
        #endif
    }

    /// A chosen capture target — a display or a window.
    ///
    /// Outlives the session capturing it, so a share can be restarted against
    /// the same target without asking the user again. That is what the macOS
    /// capture-helper respawn does with its cached `PickerSelection`.
    public final class CaptureItem {
        #if os(Windows)
        fileprivate var handle: OpaquePointer?
        #endif

        #if os(Windows)
        fileprivate init(handle: OpaquePointer) {
            self.handle = handle
        }
        #endif

        /// Show the system picker and wait for a choice.
        ///
        /// **Call this on the UI thread.** The picker is modal system UI, needs
        /// an owner window, and needs a message pump — which the shim runs
        /// while it waits.
        ///
        /// - Parameter ownerWindow: the app's HWND.
        /// - Throws: `.cancelled` if the user dismissed it.
        public static func pick(ownerWindow: UnsafeMutableRawPointer?) throws -> CaptureItem {
            #if os(Windows)
            var pointer: OpaquePointer?
            let code = ts_wgc_pick(ownerWindow, &pointer)
            guard code == 0, let pointer else { throw Error.from(code: code) }
            return CaptureItem(handle: pointer)
            #else
            _ = ownerWindow
            throw Error.unsupportedPlatform
            #endif
        }

        /// Build an item with no UI, for restarting against a remembered
        /// target.
        public static func forMonitor(_ hmonitor: UnsafeMutableRawPointer) throws -> CaptureItem {
            #if os(Windows)
            var pointer: OpaquePointer?
            let code = ts_wgc_item_for_monitor(hmonitor, &pointer)
            guard code == 0, let pointer else { throw Error.from(code: code) }
            return CaptureItem(handle: pointer)
            #else
            _ = hmonitor
            throw Error.unsupportedPlatform
            #endif
        }

        public static func forWindow(_ hwnd: UnsafeMutableRawPointer) throws -> CaptureItem {
            #if os(Windows)
            var pointer: OpaquePointer?
            let code = ts_wgc_item_for_window(hwnd, &pointer)
            guard code == 0, let pointer else { throw Error.from(code: code) }
            return CaptureItem(handle: pointer)
            #else
            _ = hwnd
            throw Error.unsupportedPlatform
            #endif
        }

        /// What the picker called it — for the sharer's own "sharing X" label.
        public var displayName: String {
            #if os(Windows)
            guard let handle else { return "" }
            var buffer = [CChar](repeating: 0, count: 256)
            guard ts_wgc_item_name(handle, &buffer, Int32(buffer.count)) == 0 else { return "" }
            return String(cString: buffer)
            #else
            return ""
            #endif
        }

        deinit {
            #if os(Windows)
            ts_wgc_item_release(handle)
            #endif
        }
    }

    /// One mapped frame. Valid only inside the `withFrame` closure.
    public struct Frame {
        public let bgra: UnsafePointer<UInt8>
        /// Row pitch in BYTES — the driver's, routinely wider than `width * 4`.
        public let stride: Int
        public let width: Int
        public let height: Int
    }

    /// An active capture on a chosen item.
    ///
    /// Not thread-safe, and does not need to be: the sharer drives it from one
    /// capture thread. It may be a different thread from the one that picked —
    /// the frame pool is created free-threaded precisely so frames do not have
    /// to be pulled on the UI thread.
    public final class Session {
        public let width: Int
        public let height: Int

        #if os(Windows)
        private var handle: OpaquePointer?
        #endif

        public init(item: CaptureItem) throws {
            #if os(Windows)
            guard let itemHandle = item.handle else { throw Error.invalidArgument }
            var pointer: OpaquePointer?
            var w: UInt32 = 0
            var h: UInt32 = 0
            let code = ts_wgc_open(itemHandle, &pointer, &w, &h)
            guard code == 0, let pointer else { throw Error.from(code: code) }
            self.handle = pointer
            self.width = Int(w)
            self.height = Int(h)
            #else
            _ = item
            self.width = 0
            self.height = 0
            throw Error.unsupportedPlatform
            #endif
        }

        deinit {
            #if os(Windows)
            ts_wgc_close(handle)
            #endif
        }

        /// Wait for a frame and hand it to `body`.
        ///
        /// - Returns: `body`'s result, or **nil when no frame arrived in
        ///   time**. That is the normal state of a still target — WGC produces
        ///   a frame only when the content changes — so it is an absent value
        ///   rather than an error, and the caller re-encodes what it has.
        ///
        /// The mapping is released before this returns, whether `body` throws
        /// or not; escaping the pointer is a use-after-unmap that the scoped
        /// shape makes hard to reach by accident.
        public func withFrame<T>(
            timeoutMilliseconds: Int = 100,
            _ body: (Frame) throws -> T
        ) throws -> T? {
            #if os(Windows)
            guard let handle else { throw Error.invalidArgument }
            var bgra: UnsafePointer<UInt8>?
            var stride: Int32 = 0
            let code = ts_wgc_acquire(handle, UInt32(timeoutMilliseconds), &bgra, &stride)
            if code == -2 { return nil }  // TS_WGC_TIMEOUT
            guard code == 0, let bgra else { throw Error.from(code: code) }
            defer { ts_wgc_release(handle) }
            return try body(
                Frame(bgra: bgra, stride: Int(stride), width: width, height: height))
            #else
            _ = timeoutMilliseconds
            _ = body
            throw Error.unsupportedPlatform
            #endif
        }
    }
}
