import Foundation

#if os(Windows)
import CDXGICapture
#endif

/// Swift face of DXGI Desktop Duplication.
///
/// Deliberately thin, like `WASAPI.Player` over the audio shim: the C++ side
/// owns the COM lifetime and this owns the Swift ergonomics — a throwing open,
/// a typed error, and a scoped frame accessor that cannot leak the mapping.
public enum DXGI {
    public enum Error: Swift.Error, CustomStringConvertible {
        case invalidArgument
        /// The adapter has no output at that index.
        case noOutput
        /// The duplication was invalidated — a mode change, a GPU switch, DWM
        /// restarting, or the secure desktop taking over. Reopen to recover.
        case accessLost
        /// A frame is still mapped.
        case busy
        case hresult(Int32)
        /// This build cannot capture — Desktop Duplication is Windows-only.
        case unsupportedPlatform

        public var description: String {
            switch self {
            case .invalidArgument: return "invalid argument"
            case .noOutput: return "no display at that output index"
            case .accessLost:
                return "the desktop duplication was invalidated (mode change, or a secure desktop)"
            case .busy: return "a frame is already mapped"
            case .hresult(let code):
                return "DXGI failed (HRESULT 0x\(String(UInt32(bitPattern: code), radix: 16)))"
            case .unsupportedPlatform:
                return "Desktop Duplication is only available on Windows"
            }
        }

        static func from(code: Int32) -> Error {
            switch code {
            case -1: return .invalidArgument
            case -3: return .accessLost
            case -4: return .noOutput
            case -5: return .busy
            default: return .hresult(code)
            }
        }
    }

    /// One mapped desktop frame. Valid only for the duration of the
    /// `withFrame` closure that produced it.
    public struct Frame {
        public let bgra: UnsafePointer<UInt8>
        /// Row pitch in BYTES — the driver's, routinely wider than `width * 4`.
        public let stride: Int
        public let width: Int
        public let height: Int
    }

    /// A duplication of one display output.
    ///
    /// Not thread-safe, and does not need to be: the sharer drives it from one
    /// capture thread.
    public final class ScreenCapture {
        public let width: Int
        public let height: Int

        #if os(Windows)
        private var handle: OpaquePointer?
        #endif

        /// - Parameter outputIndex: 0 is the primary display.
        public init(outputIndex: Int = 0) throws {
            #if os(Windows)
            var pointer: OpaquePointer?
            var w: UInt32 = 0
            var h: UInt32 = 0
            let code = ts_dxgi_open(&pointer, UInt32(outputIndex), &w, &h)
            guard code == 0, let pointer else { throw Error.from(code: code) }
            self.handle = pointer
            self.width = Int(w)
            self.height = Int(h)
            #else
            _ = outputIndex
            self.width = 0
            self.height = 0
            throw Error.unsupportedPlatform
            #endif
        }

        deinit {
            #if os(Windows)
            ts_dxgi_close(handle)
            #endif
        }

        /// Wait for a new desktop frame and hand it to `body`.
        ///
        /// - Returns: `body`'s result, or **nil when no frame arrived within
        ///   the timeout**. That is the normal state of a static screen —
        ///   Duplication produces a frame only when the desktop changes — so it
        ///   is modelled as an absent value rather than a thrown error, and the
        ///   caller re-encodes what it already has.
        ///
        /// The mapping is released before this returns, whether `body` throws
        /// or not. Escaping the pointer past the closure is a use-after-unmap;
        /// the scoped shape is what makes that hard to do by accident.
        public func withFrame<T>(
            timeoutMilliseconds: Int = 100,
            _ body: (Frame) throws -> T
        ) throws -> T? {
            #if os(Windows)
            guard let handle else { throw Error.invalidArgument }
            var bgra: UnsafePointer<UInt8>?
            var stride: Int32 = 0
            let code = ts_dxgi_acquire(handle, UInt32(timeoutMilliseconds), &bgra, &stride)
            if code == -2 { return nil }  // TS_DXGI_TIMEOUT
            guard code == 0, let bgra else { throw Error.from(code: code) }
            defer { ts_dxgi_release(handle) }
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
