import Foundation
import WGCCaptureKit

// Shows the capture picker, captures the chosen target for a moment, and
// reports what it saw.
//
// Two jobs. The first is to make the LINKER run over the WinRT shim — a SwiftPM
// library target is compiled but never linked, which is how WASAPIKit's GUID
// mistake passed its own build step and failed eleven minutes later in the app.
// This shim has more unresolved symbols than any other here (four import
// libraries plus every activation factory), so the check is worth more.
//
// The second is that it is genuinely useful to run: it prints the picked
// target's name, its size and a green-channel spread over a sparse grid, so
// "capture works" can be checked without standing up a whole share. A real
// desktop is never uniform, so a non-zero spread is the same evidence
// `scripts/e2e-linux-sharer.sh` asserts on the Linux side — a frame COUNT alone
// would happily accept a flat rectangle.
//
// It passes a null owner window, which the picker tolerates for a console
// program. The app passes its real HWND.

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
    // changes, so a still window legitimately times out. Move something if this
    // reports nothing.
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
