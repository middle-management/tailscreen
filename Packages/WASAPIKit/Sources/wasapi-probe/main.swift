import Foundation
import WASAPIKit

// Exists so CI links the WASAPI shim, not so anyone runs it — a library
// target is compiled but never linked, so an undefined symbol stays
// invisible until something downstream links it. Not run in CI (no audio
// endpoint on Windows runners); on a real desktop it prints each endpoint's
// negotiated mix format, the input `MonoPCMConverter` has to match.
do {
    let player = try WASAPI.Player()
    print("default output: \(player.format.sampleRate) Hz, \(player.format.channelCount) ch")
} catch {
    print("no usable output endpoint: \(error)")
}

// Reports peak amplitude, not just a frame count — a session recording
// silence (wrong endpoint, muted device) still delivers a healthy stream of
// zeros. Speak while it runs.
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
        // Read doesn't block; 10ms is half the 20ms Opus frame, so nothing accumulates.
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
