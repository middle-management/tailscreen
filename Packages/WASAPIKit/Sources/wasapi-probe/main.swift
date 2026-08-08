import Foundation
import WASAPIKit

// Exists so that CI links the WASAPI shim, not so that anyone runs it.
//
// A SwiftPM library target is compiled but never linked, so an undefined symbol
// in the COM shim — a GUID from the wrong import library, say — stays invisible
// until something downstream links it. That is how the first version of this
// package passed its own build step and failed in the app's link eleven minutes
// later. An executable makes the linker run against a target small enough that
// any error in it is ours.
//
// Running it is a different question and mostly a bad one: CI's Windows runners
// have no audio endpoint, so a legitimate "no device" failure would be
// indistinguishable from a broken build. On a real desktop it is a useful
// one-liner — it prints each endpoint's negotiated mix format, which is the
// input `MonoPCMConverter` has to match, and it is the ONLY way anything in this
// repo exercises the capture path end to end.
do {
    let player = try WASAPI.Player()
    print("default output: \(player.format.sampleRate) Hz, \(player.format.channelCount) ch")
} catch {
    print("no usable output endpoint: \(error)")
}

// The capture half. It reports peak amplitude rather than a frame count on
// purpose: a WASAPI capture session that is running but recording nothing —
// wrong endpoint, muted device, or the SILENT flag being copied instead of
// honoured — delivers a perfectly healthy stream of zeros, and a frame count
// cannot tell that apart from a working microphone. Speak while it runs.
do {
    let recorder = try WASAPI.Recorder()
    print("default input:  \(recorder.format.sampleRate) Hz, \(recorder.format.channelCount) ch")

    var frames = 0
    var peak: Float = 0
    var glitches = 0
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let chunk = try recorder.read()
        if chunk.discontinuity { glitches += 1 }
        frames += chunk.mono.count
        for sample in chunk.mono {
            peak = max(peak, abs(sample))
        }
        // The read does not block; without this the loop is a spin. 10 ms is
        // half the 20 ms frame the Opus path wants, so nothing accumulates.
        Thread.sleep(forTimeInterval: 0.01)
    }
    let seconds = Double(frames) / Double(recorder.format.sampleRate)
    print(
        "captured \(frames) mono frames (\(String(format: "%.2f", seconds)) s), "
            + "peak \(String(format: "%.3f", peak)), \(glitches) discontinuities")
    if peak == 0 {
        print("  …silence. Check the input device and Windows microphone privacy.")
    }
} catch {
    print("no usable input endpoint: \(error)")
}
