import CoreAudio
import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol

/// `AudioDevices.name(of:in:hal:)` — how a diagnostics line turns a CoreAudio
/// device ID into a name.
///
/// Pinned because of a 0.10.0-rc.14 bundle pair: the viewing side recorded
/// `mic.attached` with `device=unknown selection="system default"` while the
/// sharing side, same session, named the AirPods. The viewer had never opened
/// Settings or the sharer tool — the only two surfaces that fill the cached
/// device list — so a lookup that stopped at the list found nothing. Lives in
/// the app target rather than the package because `AudioDeviceID` is
/// CoreAudio's.
final class AudioDeviceNameResolutionTests: XCTestCase {
    private let builtIn = AudioDevice(
        id: 41, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
        hasInput: true, hasOutput: false)
    private let airPods = AudioDevice(
        id: 97, uid: "00-11-22-33-44-55:input", name: "AirPods Pro",
        hasInput: true, hasOutput: true)

    /// The common case, and the one that must stay cheap: a list that carries
    /// the device answers by itself, with no HAL round trip.
    func testEnumeratedListAnswersWithoutTheHAL() {
        var halAsked = false
        let name = AudioDevices.name(of: airPods.id, in: [builtIn, airPods]) { _ in
            halAsked = true
            return nil
        }

        XCTAssertEqual(name, "AirPods Pro")
        XCTAssertFalse(halAsked, "a device the list carries needs no HAL query")
    }

    /// The rc.14 viewer: nothing ever enumerated, so the list is empty. The
    /// name has to come from the HAL, and the bundle has to say "AirPods Pro",
    /// not "unknown".
    func testEmptyListFallsThroughToTheHAL() {
        let name = AudioDevices.name(of: airPods.id, in: []) { id in
            id == self.airPods.id ? "AirPods Pro" : nil
        }

        XCTAssertEqual(name, "AirPods Pro")
        XCTAssertEqual(
            AudioDeviceDiagnostics.effective(selected: nil, systemDefault: name),
            "AirPods Pro",
            "the effective device on a never-enumerated viewer must be the real one")
    }

    /// A device that arrived after the last enumeration — a headset paired
    /// while the picker was closed — is not in the list either, and the
    /// default may already have moved to it.
    func testAnIDTheListDoesNotCarryIsAskedOfTheHAL() {
        let name = AudioDevices.name(of: airPods.id, in: [builtIn]) { id in
            id == self.airPods.id ? "AirPods Pro" : nil
        }

        XCTAssertEqual(name, "AirPods Pro")
    }

    /// No default device is a real state — a machine with no inputs at all —
    /// and not a lookup to attempt: `nil` in, `nil` out, HAL untouched.
    func testNoDeviceIsNilWithoutAHALQuery() {
        var halAsked = false
        let name = AudioDevices.name(of: nil, in: [builtIn, airPods]) { _ in
            halAsked = true
            return "should not be consulted"
        }

        XCTAssertNil(name)
        XCTAssertFalse(halAsked)
    }

    /// When neither the list nor the HAL knows the device, the answer is still
    /// `nil` — which `AudioDeviceDiagnostics.effective` spells "unknown". That
    /// is the honest outcome for a vanished device, and the only path left to
    /// it now.
    func testAMissEverywhereStaysUnknown() {
        let name = AudioDevices.name(of: airPods.id, in: [builtIn]) { _ in nil }

        XCTAssertNil(name)
        XCTAssertEqual(
            AudioDeviceDiagnostics.effective(selected: nil, systemDefault: name), "unknown")
    }
}
