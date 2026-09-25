import Foundation
import WGCCaptureKit

// Shows the capture picker, captures the chosen target for a moment, and
// reports what it saw.
//
// First job: make the linker run over the WinRT shim (a library target is
// compiled but never linked otherwise). Second: genuinely useful to run — it
// prints the target's name, size and a green-channel spread over a sparse
// grid, so "capture works" is checkable without standing up a whole share
// (a non-zero spread rules out a flat rectangle, unlike a frame count alone).
//
// Passes a null owner window, which the picker tolerates for a console
// program; the app passes its real HWND.

print("wgc-probe: supported = \(WGC.isSupported)")
guard WGC.isSupported else {
    print("wgc-probe: Windows.Graphics.Capture is unavailable on this machine")
    exit(1)
}

do {
    print("wgc-probe: opening the picker — choose a window or display")
    let item = try WGC.CaptureItem.pick(ownerWindow: nil)
    print("wgc-probe: picked '\(item.displayName)'")

    let session = try WGC.Session(item: item)
    print("wgc-probe: capturing \(session.width)×\(session.height)")

    var captured = 0
    var timeouts = 0
    // Ten attempts, not ten frames: WGC yields a frame only when the target
    // changes, so a still window legitimately times out.
    for attempt in 1...10 {
        let summary = try session.withFrame(timeoutMilliseconds: 250) { frame -> String in
            var minimum = UInt8.max
            var maximum = UInt8.min
            for row in stride(from: 0, to: frame.height, by: 16) {
                for column in stride(from: 0, to: frame.width, by: 16) {
                    let byte = frame.bgra[row * frame.stride + column * 4 + 1]  // green
                    minimum = min(minimum, byte)
                    maximum = max(maximum, byte)
                }
            }
            return "stride \(frame.stride), green \(minimum)…\(maximum)"
        }

        if let summary {
            captured += 1
            print("wgc-probe: frame \(attempt): \(summary)")
        } else {
            timeouts += 1
        }
    }

    print("wgc-probe: \(captured) frame(s), \(timeouts) timeout(s)")
    if captured == 0 {
        print("wgc-probe: no frames — the target may simply not have changed; try moving a window")
    }
} catch WGC.Error.cancelled {
    // Dismissing the picker is a decision, not a fault.
    print("wgc-probe: cancelled")
} catch {
    print("wgc-probe: failed: \(error)")
    exit(1)
}
