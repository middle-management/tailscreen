import Foundation

/// Where a sharer's frame time actually goes.
///
/// A viewer's stats overlay can say the picture is arriving at 1.4 fps over a
/// 17 ms link with no loss — which proves the network is innocent and says
/// nothing at all about which part of the sharer is slow. Capture, colour
/// conversion and encode are three very different problems with three very
/// different fixes, and guessing between them from a frame rate is how an
/// afternoon disappears.
///
/// So the sharer times each stage and reports the split. Pure arithmetic, in
/// the portable tier, because every `CaptureEncoding` backend has the same
/// three stages and none of them can test this on the machine it runs on.
public struct CaptureTimings: Sendable, Equatable {
    /// Frames actually encoded per second over the window — the number a
    /// viewer sees, measured at the source.
    public let framesPerSecond: Double
    /// Mean time waiting for and mapping a frame from the platform.
    public let acquireMs: Double
    /// Mean time converting it to I420.
    public let convertMs: Double
    /// Mean time in the encoder.
    public let encodeMs: Double
    /// Frames encoded in the window.
    public let frames: Int
    /// Acquire attempts that timed out with no new frame. **Not** a fault:
    /// WGC delivers only on change, so a still screen times out by design. It
    /// is here to distinguish "the sharer is slow" from "nothing moved",
    /// which look identical from the viewer's end.
    public let timeouts: Int

    public init(
        framesPerSecond: Double, acquireMs: Double, convertMs: Double, encodeMs: Double,
        frames: Int, timeouts: Int
    ) {
        self.framesPerSecond = framesPerSecond
        self.acquireMs = acquireMs
        self.convertMs = convertMs
        self.encodeMs = encodeMs
        self.frames = frames
        self.timeouts = timeouts
    }

    /// The stage taking the most time, or nil when nothing was encoded.
    ///
    /// The one thing a person actually wants off this: *what do I fix?*
    public var slowestStage: String? {
        guard frames > 0 else { return nil }
        let stages = [("capture", acquireMs), ("convert", convertMs), ("encode", encodeMs)]
        return stages.max(by: { $0.1 < $1.1 })?.0
    }

    /// A one-line summary for a status card or a log.
    public var summary: String {
        guard frames > 0 else {
            return timeouts > 0 ? "idle — nothing on screen changed" : "starting…"
        }
        return String(
            format: "%.1f fps · capture %.0f ms · convert %.0f ms · encode %.0f ms",
            framesPerSecond, acquireMs, convertMs, encodeMs)
    }
}

/// Accumulates per-frame stage timings and emits a `CaptureTimings` once per
/// window.
///
/// Deliberately a value type with an injected clock: a capture loop calls
/// `record` on every iteration from its own thread and asks for a snapshot in
/// the same breath, so the whole thing has to be cheap and has to be testable
/// without waiting a real second.
public struct CaptureTimingAccumulator: Sendable {
    /// How often a snapshot is produced. One second: long enough that a single
    /// slow frame doesn't dominate, short enough to watch a change take effect.
    public static let windowNs: UInt64 = 1_000_000_000

    private var windowStartNs: UInt64?
    private var acquireNs: UInt64 = 0
    private var convertNs: UInt64 = 0
    private var encodeNs: UInt64 = 0
    private var frames = 0
    private var timeouts = 0

    public init() {}

    /// Record one pass of the capture loop.
    ///
    /// - Parameter producedFrame: false when the acquire timed out, so the
    ///   pass counts as a timeout and its (zero) convert/encode times are not
    ///   averaged in. Including them would drag every average toward zero on a
    ///   still screen and report a fast sharer that is doing nothing.
    public mutating func record(
        nowNs: UInt64,
        acquireNs: UInt64,
        convertNs: UInt64,
        encodeNs: UInt64,
        producedFrame: Bool
    ) {
        if windowStartNs == nil { windowStartNs = nowNs }
        self.acquireNs += acquireNs
        if producedFrame {
            self.convertNs += convertNs
            self.encodeNs += encodeNs
            frames += 1
        } else {
            timeouts += 1
        }
    }

    /// A snapshot, if a full window has elapsed. Resets the window when it
    /// returns one.
    public mutating func snapshot(nowNs: UInt64) -> CaptureTimings? {
        guard let start = windowStartNs else { return nil }
        let elapsed = nowNs &- start
        guard elapsed >= Self.windowNs else { return nil }

        let passes = frames + timeouts
        let seconds = Double(elapsed) / 1_000_000_000
        let timings = CaptureTimings(
            framesPerSecond: seconds > 0 ? Double(frames) / seconds : 0,
            // Acquire is averaged over every pass, the other two over encoded
            // frames only: a timeout still spent time waiting, but converted
            // and encoded nothing.
            acquireMs: passes > 0 ? Double(acquireNs) / Double(passes) / 1_000_000 : 0,
            convertMs: frames > 0 ? Double(convertNs) / Double(frames) / 1_000_000 : 0,
            encodeMs: frames > 0 ? Double(encodeNs) / Double(frames) / 1_000_000 : 0,
            frames: frames,
            timeouts: timeouts)

        windowStartNs = nowNs
        acquireNs = 0
        convertNs = 0
        encodeNs = 0
        frames = 0
        timeouts = 0
        return timings
    }
}
