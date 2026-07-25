import CX11Capture
import Foundation

/// X11 screen capture, producing the tightly-packed I420 planes a video
/// encoder consumes.
///
/// This is the capture half of a Linux `CaptureEncoding` backend. It grabs the
/// root window of an X display — through MIT-SHM when the server offers it, so
/// a frame costs a round trip rather than a full-screen transfer — and
/// converts to **limited-range BT.709** I420, which is the exact convention
/// the viewer's YUV→RGB shader expects.
///
/// Scope, stated plainly: root-window capture only. Per-window and per-app
/// capture, and Wayland, belong to the `org.freedesktop.portal.ScreenCast`
/// backend; this one exists because it is the capture path that can run
/// headlessly in CI (Xvfb), which the portal never can.
public final class X11ScreenCapture: @unchecked Sendable {
    public struct OpenError: Error, CustomStringConvertible {
        public let description: String
    }

    public struct GrabError: Error, CustomStringConvertible {
        public let code: Int32
        public var description: String {
            switch code {
            case -1: return "invalid capture geometry"
            case -2: return "X11 grab failed (server gone, or the screen resized)"
            default: return "X11 grab failed (\(code))"
            }
        }
    }

    private let handle: OpaquePointer

    /// The captured screen's full size. ``captureWidth`` / ``captureHeight``
    /// are what frames are actually produced at.
    public let screenWidth: Int
    public let screenHeight: Int

    /// Even-rounded capture geometry. H.264's 4:2:0 chroma is half-resolution
    /// in both axes, so an odd screen dimension has to lose its last row or
    /// column; doing it here (rather than letting libavcodec pad) keeps the
    /// encoder's idea of the frame and ours identical.
    public var captureWidth: Int { screenWidth & ~1 }
    public var captureHeight: Int { screenHeight & ~1 }

    /// Whether the zero-copy MIT-SHM path is in use. Diagnostic only — pixels
    /// are identical either way, but the fallback costs a full-screen transfer
    /// per frame and is worth logging on a slow share.
    public let usesSharedMemory: Bool

    /// - Parameter display: an X display string (`":0"`), or nil for `$DISPLAY`.
    public init(display: String? = nil) throws {
        let h: OpaquePointer? =
            display.map { d in d.withCString { x11cap_open($0) } } ?? x11cap_open(nil)
        guard let h else {
            throw OpenError(
                description:
                    "cannot open X display \(display ?? ProcessInfo.processInfo.environment["DISPLAY"] ?? "(unset)")"
            )
        }
        handle = h
        var w: Int32 = 0
        var hgt: Int32 = 0
        x11cap_size(h, &w, &hgt)
        screenWidth = Int(w)
        screenHeight = Int(hgt)
        usesSharedMemory = x11cap_uses_shm(h) != 0
        guard screenWidth >= 2, screenHeight >= 2 else {
            x11cap_close(h)
            throw OpenError(description: "X display is \(screenWidth)x\(screenHeight); too small to capture")
        }
    }

    deinit {
        x11cap_close(handle)
    }

    /// One captured frame as tightly-packed I420 planes.
    public struct Planes: Sendable {
        public let width: Int
        public let height: Int
        public var y: [UInt8]
        public var u: [UInt8]
        public var v: [UInt8]
    }

    /// Allocate planes sized for this capture. Callers hold one set and reuse
    /// it across frames (see ``grab(into:)``) rather than allocating per frame
    /// at 60 fps.
    public func makePlanes() -> Planes {
        let w = captureWidth
        let h = captureHeight
        let cw = w / 2
        let ch = h / 2
        return Planes(
            width: w, height: h,
            y: [UInt8](repeating: 0, count: w * h),
            u: [UInt8](repeating: 128, count: cw * ch),
            v: [UInt8](repeating: 128, count: cw * ch))
    }

    /// Grab the current screen into `planes`, reusing its storage.
    public func grab(into planes: inout Planes) throws {
        let w = Int32(planes.width)
        let h = Int32(planes.height)
        var rc: Int32 = 0
        planes.y.withUnsafeMutableBufferPointer { yb in
            planes.u.withUnsafeMutableBufferPointer { ub in
                planes.v.withUnsafeMutableBufferPointer { vb in
                    guard let y = yb.baseAddress, let u = ub.baseAddress, let v = vb.baseAddress else {
                        rc = -1
                        return
                    }
                    rc = x11cap_grab_i420(handle, y, u, v, w, h)
                }
            }
        }
        if rc != 0 { throw GrabError(code: rc) }
    }

    /// Convert a packed BGRA buffer to I420 with the same limited-range BT.709
    /// math the capture path uses. Exposed so the conversion is testable
    /// without an X server.
    public static func convertBGRA(
        _ bgra: [UInt8], stride: Int, width: Int, height: Int
    ) -> Planes {
        let cw = width / 2
        let ch = height / 2
        var y = [UInt8](repeating: 0, count: max(0, width * height))
        var u = [UInt8](repeating: 128, count: max(0, cw * ch))
        var v = [UInt8](repeating: 128, count: max(0, cw * ch))
        bgra.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            y.withUnsafeMutableBufferPointer { yb in
                u.withUnsafeMutableBufferPointer { ub in
                    v.withUnsafeMutableBufferPointer { vb in
                        guard let yp = yb.baseAddress, let up = ub.baseAddress, let vp = vb.baseAddress
                        else { return }
                        x11cap_bgra_to_i420(
                            base, Int32(stride), yp, up, vp, Int32(width), Int32(height))
                    }
                }
            }
        }
        return Planes(width: width, height: height, y: y, u: u, v: v)
    }
}
