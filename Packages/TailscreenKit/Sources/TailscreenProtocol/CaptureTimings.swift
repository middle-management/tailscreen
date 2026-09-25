import Foundation

/// Where a sharer's frame time actually goes. A viewer's stats overlay can
/// show low fps over a clean link, which proves the network innocent but says
/// nothing about which sharer stage is slow — capture, colour conversion and
/// encode are different problems with different fixes. So the sharer times
/// each stage and reports the split. Pure arithmetic in the portable tier,
/// since every `CaptureEncoding` backend has the same three stages.
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
    /// Acquire attempts that timed out with no new frame. Not a fault — WGC
    /// delivers only on change — but distinguishes "sharer is slow" from
    /// "nothing moved", which look identical to the viewer.
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

    /// The stage taking the most time, or nil when nothing was encoded — the
    /// one thing a person actually wants off this.
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
        let stages = String(
            format: "%.1f fps · capture %.0f ms · convert %.0f ms · encode %.0f ms",
            framesPerSecond, acquireMs, convertMs, encodeMs)
        // The idle count separates "sharer is slow" from "nothing moved" —
        // omitted when zero so a busy screen reads cleanly.
        guard timeouts > 0 else { return stages }
        return "\(stages) · \(timeouts) idle"
    }
}

/// Accumulates per-frame stage timings and emits a `CaptureTimings` once per
/// window. A value type with an injected clock, so a capture loop can call
/// `record` and snapshot cheaply and testably without waiting a real second.
public struct CaptureTimingAccumulator: Sendable {
    /// How often a snapshot is produced. One second: long enough that a
    /// single slow frame doesn't dominate, short enough to see a change take effect.
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
    /// - Parameter producedFrame: false when the acquire timed out; its
    ///   (zero) convert/encode times are excluded from the average, or a
    ///   still screen would report a falsely fast sharer.
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
            // Acquire averages over every pass; convert/encode over encoded frames only.
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
