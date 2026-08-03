import Foundation
import TailscreenProtocol

/// The hand-off of converted I420 frames from PipeWire's thread to the encode
/// thread.
///
/// Its own type because it is the only genuinely concurrent thing in this
/// backend, and because a bug in it is silent: a torn frame is a moment of
/// visible garbage on somebody's screen and nothing in any log. Isolating it
/// means the invariant can be tested with real threads and no PipeWire, no
/// portal, no encoder and no consent dialog.
///
/// **Why two buffers rather than one lock.** The obvious version — convert and
/// encode under the same lock — makes PipeWire's thread wait out an x264
/// encode, which at 1080p is comfortably longer than the frame interval. A
/// thread that stops servicing the graph is one PipeWire starts dropping
/// buffers on, so the stutter would show up on the *sharer's* whole desktop,
/// not just in the share. Here the lock is held for a few instructions at a
/// time and never across a conversion or an encode.
///
/// **The invariant**, and the whole reason this is a type:
///
/// > The encoder never reads a buffer the converter is writing.
///
/// It holds because only the encode thread ever swaps, and it only swaps when
/// the converter is provably not inside `write` — the `writing` flag is raised
/// and lowered under the same lock the swap takes.
///
/// Latest-wins by construction: a frame converted while the encoder is busy
/// simply overwrites the previous unpublished one. That is right for a screen
/// share, where the newest picture is the only interesting one.
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
    /// - Returns: the planes to encode, and whether they are new since the last
    ///   call. A non-new result is still returned rather than nil, because the
    ///   encode thread needs the last picture to answer a keyframe request
    ///   while the screen is still — a compositor sends nothing at all then,
    ///   and a viewer joining during a motionless moment would otherwise wait
    ///   for the user to move something before it could decode anything.
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

    /// Re-make both buffers at a new geometry, discarding what was in them.
    ///
    /// Keeping the old front across a resize would leave the encoder reading
    /// planes sized for the previous resolution on its very next pass.
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
