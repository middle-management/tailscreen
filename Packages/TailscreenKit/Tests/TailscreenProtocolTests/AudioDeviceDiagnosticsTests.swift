import Foundation
import XCTest

@testable import TailscreenProtocol

/// `AudioDeviceDiagnostics` — what a bundle says about the audio devices a
/// session had to choose from.
///
/// Worth pinning because the failure it exists to distinguish is one of the
/// most common and least visible there is. "They couldn't hear me" has two
/// causes that look identical from outside: the right device was in the list
/// and the wrong one was selected, or the right device was **never in the
/// list** and could not have been selected. Recording only the selection
/// answers the first and is silent about the second.
final class AudioDeviceDiagnosticsTests: XCTestCase {

    // MARK: - Rendering

    /// Order is preserved rather than sorted: the host enumerates in the order
    /// the pickers show, and a reader comparing a bundle against a screenshot
    /// of the picker should see the same sequence.
    func testDescribePreservesEnumerationOrder() {
        XCTAssertEqual(
            AudioDeviceDiagnostics.describe(["MacBook Pro Microphone", "Jabra Evolve2 65"]),
            "MacBook Pro Microphone, Jabra Evolve2 65")
    }

    /// "none" rather than an empty string — an empty value in a `key=value`
    /// line reads as a bug in the recorder rather than as a machine with no
    /// inputs, which is itself a real and diagnostic state.
    func testEmptyListIsNamed() {
        XCTAssertEqual(AudioDeviceDiagnostics.describe([]), "none")
    }

    /// A studio interface can enumerate dozens of channels, and one event that
    /// is four kilobytes of device names would push the rest of the session
    /// out of the buffer. Past the cap the names stop — but the count does
    /// not, so the most important part stays exact.
    func testLongListIsCappedButTheCountSurvives() {
        let names = (1...30).map { "Device \($0)" }
        let rendered = AudioDeviceDiagnostics.describe(names)

        XCTAssertTrue(rendered.contains("Device 1"))
        XCTAssertTrue(
            rendered.hasSuffix("+\(30 - AudioDeviceDiagnostics.maximumNamedDevices) more"),
            rendered)
        XCTAssertFalse(rendered.contains("Device 30"))

        let fields = AudioDeviceDiagnostics.fields(
            inputs: names, outputs: [], selectedInput: nil, selectedOutput: nil)
        XCTAssertEqual(
            fields["input_count"], .int(30),
            "the count must stay exact even when the names are truncated")
    }

    /// Exactly at the cap nothing is elided — an off-by-one here would add a
    /// "+0 more" that reads as truncation which did not happen.
    func testListExactlyAtTheCapIsNotTruncated() {
        let names = (1...AudioDeviceDiagnostics.maximumNamedDevices).map { "Device \($0)" }
        let rendered = AudioDeviceDiagnostics.describe(names)
        XCTAssertFalse(rendered.contains("more"), rendered)
    }

    // MARK: - Change detection

    /// The first enumeration is the baseline and always worth one event.
    func testFirstEnumerationIsAChange() {
        XCTAssertTrue(AudioDeviceDiagnostics.changed(from: nil, to: ["Built-in"]))
    }

    /// The common case: a picker re-rendering must not emit an event. This is
    /// what keeps the session legible — the host enumerates many times and
    /// almost always gets the same answer.
    func testUnchangedListIsNotRecordedAgain() {
        XCTAssertFalse(
            AudioDeviceDiagnostics.changed(from: ["Built-in", "Jabra"], to: ["Built-in", "Jabra"]))
    }

    /// A device arriving or leaving mid-session is frequently the entire
    /// diagnosis — a Bluetooth headset dropping out is invisible to the user
    /// beyond "it stopped working".
    func testDeviceArrivalAndDepartureAreChanges() {
        XCTAssertTrue(AudioDeviceDiagnostics.changed(from: ["Built-in"], to: ["Built-in", "Jabra"]))
        XCTAssertTrue(AudioDeviceDiagnostics.changed(from: ["Built-in", "Jabra"], to: ["Built-in"]))
    }

    /// Compared as an ordered list, not a set. A reordering means the system
    /// default moved, which changes what an unselected "System Default" pick
    /// resolves to — a real change in what the session records from, and
    /// exactly the kind that otherwise goes unexplained.
    func testReorderingCountsAsAChange() {
        XCTAssertTrue(
            AudioDeviceDiagnostics.changed(from: ["Built-in", "Jabra"], to: ["Jabra", "Built-in"]))
    }

    // MARK: - Fields

    /// Both halves are present: what existed, and what was chosen.
    func testFieldsCarryAvailabilityAndSelection() {
        let fields = AudioDeviceDiagnostics.fields(
            inputs: ["Built-in", "Jabra"],
            outputs: ["Built-in Output"],
            selectedInput: "Jabra",
            selectedOutput: nil)

        XCTAssertEqual(fields["inputs"], .string("Built-in, Jabra"))
        XCTAssertEqual(fields["input_count"], .int(2))
        XCTAssertEqual(fields["outputs"], .string("Built-in Output"))
        XCTAssertEqual(fields["output_count"], .int(1))
        XCTAssertEqual(fields["selected_input"], .string("Jabra"))
    }

    /// No explicit pick is spelled out rather than omitted. "System default"
    /// is a real state and a common answer to "why was it using the built-in
    /// mic", where a missing field would just look like missing data.
    func testNoExplicitSelectionIsNamedNotOmitted() {
        let fields = AudioDeviceDiagnostics.fields(
            inputs: ["Built-in"], outputs: ["Built-in"],
            selectedInput: nil, selectedOutput: nil)

        XCTAssertEqual(fields["selected_input"], .string("system default"))
        XCTAssertEqual(fields["selected_output"], .string("system default"))
    }

    /// The case the whole type exists for: a bundle must show that the device
    /// somebody expected was not on the machine at all.
    func testAMissingDeviceIsVisibleInTheRecord() {
        let fields = AudioDeviceDiagnostics.fields(
            inputs: ["MacBook Pro Microphone"],
            outputs: ["MacBook Pro Speakers"],
            selectedInput: nil,
            selectedOutput: nil)

        guard case .string(let inputs)? = fields["inputs"] else {
            return XCTFail("inputs field missing")
        }
        XCTAssertFalse(
            inputs.contains("Jabra"),
            "the headset the user expected is absent, and the bundle shows it")
    }
}
