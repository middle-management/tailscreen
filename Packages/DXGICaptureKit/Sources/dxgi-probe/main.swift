import DXGICaptureKit
import Foundation

// Opens a desktop duplication, grabs a few frames, and reports what it saw.
//
// Two jobs. The first is to make the LINKER run over the COM shim — a SwiftPM
// library target is compiled but never linked, which is how WASAPIKit's GUID
// mistake passed its own build step and failed eleven minutes later in the app.
//
// The second is that, unlike the audio probe, this one is genuinely useful to
// run: it prints the captured geometry and a cheap pixel summary, so "capture
// works" can be checked without standing up a whole share. A frame of a real
// desktop is never uniform, so a non-zero spread is the same evidence
// `scripts/e2e-linux-sharer.sh` asserts on the Linux side — a frame COUNT alone
// would accept a flat rectangle.

let outputIndex = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 0
print("dxgi-probe: opening output \(outputIndex)")

do {
    let capture = try DXGI.ScreenCapture(outputIndex: outputIndex)
    print("dxgi-probe: duplication open — \(capture.width)×\(capture.height)")

    var captured = 0
    var timeouts = 0
    // Ten attempts, not ten frames: Duplication yields a frame only when the
    // desktop changes, so on a still screen most attempts legitimately time
    // out. Move the mouse if this reports nothing.
    for attempt in 1...10 {
        let summary = try capture.withFrame(timeoutMilliseconds: 250) { frame -> String in
            var minimum = UInt8.max
            var maximum = UInt8.min
            // Sample a sparse grid rather than every pixel: enough to tell a
            // real desktop from a flat fill, cheap enough not to distort what
            // the capture path costs.
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
            print("dxgi-probe: frame \(attempt): \(summary)")
        } else {
            timeouts += 1
        }
    }

    print("dxgi-probe: \(captured) frame(s), \(timeouts) timeout(s)")
    if captured == 0 {
        print("dxgi-probe: no frames — the desktop may simply not have changed; try moving the mouse")
    }
} catch {
    print("dxgi-probe: failed: \(error)")
    exit(1)
}
