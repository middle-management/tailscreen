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
// one-liner — it prints the endpoint's negotiated mix format, which is the
// input `MonoPCMConverter` has to match.
do {
    let player = try WASAPI.Player()
    print("default endpoint: \(player.format.sampleRate) Hz, \(player.format.channelCount) ch")
} catch {
    print("no usable output endpoint: \(error)")
}
