import Foundation

#if os(Windows)
import CWASAPI
#endif

/// Swift face of the WASAPI shared-mode render session.
///
/// Deliberately thin: the C shim owns the COM lifetime and this owns the Swift
/// ergonomics — a throwing open, a typed error, and an array-shaped write. Same
/// split as `ALSA.PCMPlayer` over libasound.
public enum WASAPI {
    /// What the endpoint negotiated. Shared mode does not accept anything else,
    /// so the caller converts its PCM to match.
    public struct Format: Equatable, Sendable {
        public let sampleRate: Int
        public let channelCount: Int

        public init(sampleRate: Int, channelCount: Int) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
        }
    }

    /// `Equatable` so the code→case mapping can be asserted directly; it is the
    /// one part of this file that runs on every platform.
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// The endpoint's mix format is not 32-bit float, so our samples cannot
        /// be written to it without a conversion the shim refuses to guess at.
        case unsupportedFormat
        case invalidArgument
        /// The device stopped draining for longer than the write timeout.
        case timedOut
        /// A capture read was handed a buffer too small for one packet. Not
        /// reachable through `Recorder`, which sizes its own.
        case bufferTooSmall
        /// Windows refused the microphone: Settings → Privacy & security →
        /// Microphone. Its own case rather than an opaque HRESULT because it is
        /// the one failure here that the user can fix, and a message naming
        /// 0x80070005 tells them nothing.
        case accessDenied
        /// A COM failure, carrying its HRESULT so the log names the real cause.
        case hresult(Int32)
        /// This build cannot play audio at all — WASAPI is Windows-only.
        case unsupportedPlatform

        public var description: String {
            switch self {
            case .unsupportedFormat:
                return "the audio endpoint's mix format is not 32-bit float"
            case .invalidArgument:
                return "invalid argument"
            case .timedOut:
                return "the audio endpoint stopped accepting data"
            case .bufferTooSmall:
                return "the read buffer cannot hold one capture packet"
            case .accessDenied:
                return "Windows is blocking microphone access for this app"
            case .hresult(let code):
                return "WASAPI failed (HRESULT 0x\(String(UInt32(bitPattern: code), radix: 16)))"
            case .unsupportedPlatform:
                return "WASAPI is only available on Windows"
            }
        }

        /// The HRESULT Windows returns when the microphone privacy setting is
        /// off. Spelled as a bit pattern because `E_ACCESSDENIED` is an SDK
        /// macro that does not exist off Windows, and this mapping has to be
        /// testable where the tests run.
        static let accessDeniedHResult = Int32(bitPattern: 0x8007_0005)

        /// Map the shim's return code. Zero is success and must be filtered by
        /// the caller before this is consulted.
        ///
        /// Negative values are the shim's own; everything else is a raw HRESULT,
        /// which keeps its identity all the way to the log line instead of
        /// collapsing into "audio failed".
        static func from(code: Int32) -> Error {
            switch code {
            case -1: return .unsupportedFormat
            case -2: return .invalidArgument
            case -3: return .timedOut
            case -4: return .bufferTooSmall
            case accessDeniedHResult: return .accessDenied
            default: return .hresult(code)
            }
        }
    }

    /// A started render session on the default output endpoint.
    ///
    /// **Thread affinity:** create it and write to it from the SAME thread. COM
    /// apartment state is per-thread and `init` initialises the calling thread's
    /// apartment. Callers get this for free by constructing lazily inside
    /// `ThreadedAudioSink`'s drain thread.
    public final class Player {
        public let format: Format

        #if os(Windows)
        private var handle: OpaquePointer?
        #endif

        public init() throws {
            #if os(Windows)
            // `ts_wasapi` is incomplete in the header, so Swift imports every
            // `ts_wasapi *` as `OpaquePointer` — no rebinding, and no way to
            // reach inside the struct from here, which is the point of it.
            var pointer: OpaquePointer?
            var rate: UInt32 = 0
            var channels: UInt32 = 0
            let code = ts_wasapi_open(&pointer, &rate, &channels)
            guard code == 0, let pointer else {
                throw Error.from(code: code)
            }
            self.handle = pointer
            self.format = Format(sampleRate: Int(rate), channelCount: Int(channels))
            #else
            throw Error.unsupportedPlatform
            #endif
        }

        deinit {
            #if os(Windows)
            ts_wasapi_close(handle)
            #endif
        }

        /// Write interleaved float frames, blocking until the engine has taken
        /// them all.
        ///
        /// - Parameter interleaved: `frames × channelCount` samples in [-1, 1].
        public func write(_ interleaved: [Float]) throws {
            #if os(Windows)
            guard let handle else { throw Error.invalidArgument }
            guard !interleaved.isEmpty else { return }
            let frames = UInt32(interleaved.count / format.channelCount)
            guard frames > 0 else { return }
            let code = interleaved.withUnsafeBufferPointer {
                ts_wasapi_write(handle, $0.baseAddress, frames)
            }
            guard code == 0 else { throw Error.from(code: code) }
            #else
            throw Error.unsupportedPlatform
            #endif
        }
    }
}
