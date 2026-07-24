import Foundation
import SDLKit
import TailscreenProtocol
import TailscreenViewer

/// Adapts `SDLKit`'s YUV window to the viewer core's `VideoSink`, driving **all**
/// SDL calls from a single dedicated thread.
///
/// SDL's window, renderer, and event queue must be created and used from one
/// consistent thread. The transport that feeds this sink runs as a Swift
/// `@MainActor` async loop, whose executor is not guaranteed to stay on one OS
/// thread across `await` points on Linux — so presenting directly from there
/// left the window silently unpainted (SDL no-ops rendering off its owning
/// thread, no error). Instead this sink owns a render thread that creates the
/// window and runs a continuous loop: pump events, present the latest decoded
/// frame (re-presenting it when idle so a static screen doesn't blank to white
/// on expose — the mac renderer's display-link, by hand). `present()` just
/// hands over the newest frame under a lock; the transport never touches SDL.
public final class ThreadedSDLVideoSink: VideoSink, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: DecodedVideoFrame?
    private var closed = false
    private var startupError: Error?
    private let ready = DispatchSemaphore(value: 0)

    /// Spawns the render thread and blocks until the window is up (or throws if
    /// window creation failed on that thread).
    public init(title: String, width: Int, height: Int, softwareRenderer: Bool) throws {
        let thread = Thread { [self] in
            renderLoop(title: title, width: width, height: height, softwareRenderer: softwareRenderer)
        }
        thread.name = "sdl-render"
        thread.stackSize = 4 << 20
        thread.start()
        ready.wait()
        lock.lock()
        let err = startupError
        lock.unlock()
        if let err { throw err }
    }

    /// Hand the newest frame to the render thread (drops any not-yet-shown
    /// frame — only the latest matters for display). Never calls SDL. The
    /// portable seam is codec-agnostic (`any DecodedFrame`); this SDL sink only
    /// understands CPU I420, so a non-`DecodedVideoFrame` is dropped (it can't
    /// arise here — the paired `FFmpegVideoDecoder` only emits that type).
    public func present(_ frame: any DecodedFrame) {
        guard let frame = frame as? DecodedVideoFrame else { return }
        lock.lock()
        latest = frame
        lock.unlock()
    }

    /// True once the user closed the window (observed on the render thread).
    public func pollShouldClose() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func renderLoop(title: String, width: Int, height: Int, softwareRenderer: Bool) {
        let window: SDL.VideoWindow
        do {
            window = try SDL.VideoWindow(
                title: title, width: width, height: height, softwareRenderer: softwareRenderer)
        } catch {
            lock.lock()
            startupError = error
            lock.unlock()
            ready.signal()
            return
        }
        ready.signal()

        while true {
            if window.pollShouldClose() {
                lock.lock()
                closed = true
                lock.unlock()
                break
            }
            lock.lock()
            let frame = latest
            lock.unlock()
            if let frame {
                do {
                    try window.present(
                        width: frame.width, height: frame.height,
                        yPlane: frame.yPlane, uPlane: frame.uPlane, vPlane: frame.vPlane)
                } catch {
                    FileHandle.standardError.write(Data("SDL present failed: \(error)\n".utf8))
                }
            }
            Thread.sleep(forTimeInterval: 1.0 / 60.0)
        }
    }
}
