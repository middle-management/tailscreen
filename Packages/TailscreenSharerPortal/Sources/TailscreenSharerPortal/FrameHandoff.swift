import Foundation
import TailscreenProtocol

/// The hand-off of converted I420 frames from PipeWire's thread to the
/// encode thread. Its own type so the invariant is testable with real
/// threads and no PipeWire/portal/encoder.
///
/// **Two buffers rather than one lock**: encoding under the same lock as
/// conversion would make PipeWire's thread wait out an x264 encode (longer
/// than one frame interval at 1080p), and PipeWire starts dropping buffers
/// on a thread that stops servicing the graph — stuttering the sharer's
/// whole desktop, not just the share. Here the lock is held only for a swap.
///
/// **The invariant:** the encoder never reads a buffer the converter is
/// writing. Holds because only the encode thread swaps, and only when the
/// `writing` flag (raised/lowered under the same lock) says the converter
/// isn't mid-`write`.
///
/// Latest-wins by construction: a frame converted while the encoder is busy
/// overwrites the previous unpublished one — right for a screen share, where
/// only the newest picture matters.
final class FrameHandoff: @unchecked Sendable {
    /// One set of I420 planes, sized for one encoder configuration.
    final class Planes {
        var y: [UInt8]
        var u: [UInt8]
        var v: [UInt8]
        let width: Int
        let height: Int

        init(width: Int, height: Int) {
            let sizes = BGRAToI420.planeSizes(width: width, height: height)
            self.y = [UInt8](repeating: 0, count: sizes.y)
            // Neutral chroma, so a buffer read before anything is converted
            // into it is grey rather than green.
            self.u = [UInt8](repeating: 128, count: sizes.chroma)
            self.v = [UInt8](repeating: 128, count: sizes.chroma)
            self.width = width
            self.height = height
        }
    }

    private let lock = NSLock()
    private var front: Planes
    private var back: Planes
    private var backDirty = false
    private var writing = false

    private(set) var width: Int
    private(set) var height: Int

    init(width: Int, height: Int) {
        self.front = Planes(width: width, height: height)
        self.back = Planes(width: width, height: height)
        self.width = width
        self.height = height
    }

    /// Convert into the back buffer.
    ///
    /// - Parameter body: performs the conversion; returns whether it produced
    ///   a usable frame. **Runs outside the lock** — that is the point of the
    ///   type — so it must touch nothing but the planes it is handed.
    ///
    /// Reentrancy is not supported and not needed: one PipeWire thread calls
    /// this, serially.
    func write(_ body: (Planes) -> Bool) {
        let target = lock.withLock { () -> Planes in
            writing = true
            return back
        }
        let produced = body(target)
        lock.withLock {
            writing = false
            if produced { backDirty = true }
        }
    }

    /// Publish the newest converted frame, if there is one and the converter
    /// is not mid-write.
    ///
    /// - Returns: the planes to encode, and whether they are new. A non-new
    ///   result is still returned (not nil) — the encode thread needs the
    ///   last picture to answer a keyframe request while the screen is
    ///   still, when the compositor sends nothing at all.
    func publish() -> (planes: Planes, isNew: Bool) {
        lock.withLock {
            guard backDirty, !writing else { return (front, false) }
            swap(&front, &back)
            backDirty = false
            hasPublished = true
            return (front, true)
        }
    }

    /// Whether anything has ever been published. Until it has, `publish`
    /// returns the initial grey buffer, which must not be encoded and sent to
    /// viewers as though it were the sharer's screen.
    var hasFrame: Bool {
        lock.withLock { hasPublished }
    }

    private var hasPublished = false

    /// Re-make both buffers at a new geometry — keeping the old front would
    /// leave the encoder reading planes sized for the previous resolution.
    func resize(width: Int, height: Int) {
        lock.withLock {
            front = Planes(width: width, height: height)
            back = Planes(width: width, height: height)
            backDirty = false
            writing = false
            hasPublished = false
            self.width = width
            self.height = height
        }
    }
}
