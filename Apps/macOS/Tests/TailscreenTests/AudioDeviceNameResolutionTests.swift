import CoreAudio
import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol

/// `AudioDevices.name(of:in:hal:)` — how a diagnostics line turns a CoreAudio
/// device ID into a name.
///
/// Pins a regression where a viewer that never opened Settings or the sharer
/// tool (so its cached device list stayed empty) logged `device=unknown` for
/// a device the HAL could still have named. Lives in the app target, not the
/// package, because `AudioDeviceID` is CoreAudio's.
final class AudioDeviceNameResolutionTests: XCTestCase {
    private let builtIn = AudioDevice(
        id: 41, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
        hasInput: true, hasOutput: false)
    private let airPods = AudioDevice(
        id: 97, uid: "00-11-22-33-44-55:input", name: "AirPods Pro",
        hasInput: true, hasOutput: true)

    /// A list that carries the device answers by itself, with no HAL round trip.
    func testEnumeratedListAnswersWithoutTheHAL() {
        var halAsked = false
        let name = AudioDevices.name(of: airPods.id, in: [builtIn, airPods]) { _ in
            halAsked = true
            return nil
        }

        XCTAssertEqual(name, "AirPods Pro")
        XCTAssertFalse(halAsked, "a device the list carries needs no HAL query")
    }

    /// Nothing ever enumerated (empty list): the name must fall through to the HAL.
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

    /// A device that arrived after the last enumeration is not in the list either.
    func testAnIDTheListDoesNotCarryIsAskedOfTheHAL() {
        let name = AudioDevices.name(of: airPods.id, in: [builtIn]) { id in
            id == self.airPods.id ? "AirPods Pro" : nil
        }

        XCTAssertEqual(name, "AirPods Pro")
    }

    /// No default device (machine with no inputs) is `nil` in, `nil` out, HAL untouched.
    func testNoDeviceIsNilWithoutAHALQuery() {
        var halAsked = false
        let name = AudioDevices.name(of: nil, in: [builtIn, airPods]) { _ in
            halAsked = true
            return "should not be consulted"
        }

        XCTAssertNil(name)
        XCTAssertFalse(halAsked)
    }

    /// Neither list nor HAL knows the device: stays `nil`, spelled "unknown".
    func testAMissEverywhereStaysUnknown() {
        let name = AudioDevices.name(of: airPods.id, in: [builtIn]) { _ in nil }

        XCTAssertNil(name)
        XCTAssertEqual(
            AudioDeviceDiagnostics.effective(selected: nil, systemDefault: name), "unknown")
    }
}
