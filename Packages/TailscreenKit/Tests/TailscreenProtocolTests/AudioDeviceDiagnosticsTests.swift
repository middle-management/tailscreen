import Foundation
import XCTest

@testable import TailscreenProtocol

/// `AudioDeviceDiagnostics` — what a bundle says about the audio devices a
/// session had to choose from. "They couldn't hear me" has two causes that
/// look identical from outside: the wrong device was selected, or the right
/// device was never in the list at all. Recording only the selection
/// answers the first and is silent about the second.
final class AudioDeviceDiagnosticsTests: XCTestCase {

    // MARK: - Rendering

    /// Order is preserved rather than sorted, matching the picker's order.
    func testDescribePreservesEnumerationOrder() {
        XCTAssertEqual(
            AudioDeviceDiagnostics.describe(["MacBook Pro Microphone", "Jabra Evolve2 65"]),
            "MacBook Pro Microphone, Jabra Evolve2 65")
    }

    /// "none" rather than an empty string — an empty value in a `key=value`
    /// line reads as a recorder bug, not a machine with no inputs.
    func testEmptyListIsNamed() {
        XCTAssertEqual(AudioDeviceDiagnostics.describe([]), "none")
    }

    /// Past the cap the names stop, but the count doesn't — a studio
    /// interface's dozens of channels shouldn't push the session out of
    /// the buffer.
    func testLongListIsCappedButTheCountSurvives() {
        let names = (1...30).map { "Device \($0)" }
        let rendered = AudioDeviceDiagnostics.describe(names)

        XCTAssertTrue(rendered.contains("Device 1"))
        XCTAssertTrue(
            rendered.hasSuffix("+\(30 - AudioDeviceDiagnostics.maximumNamedDevices) more"),
            rendered)
        XCTAssertFalse(rendered.contains("Device 30"))

        let fields = AudioDeviceDiagnostics.fields(
            snapshot: snapshot(names), selectedInput: nil, selectedOutput: nil)
        XCTAssertEqual(
            fields["input_count"], .int(30),
            "the count must stay exact even when the names are truncated")
    }

    /// An off-by-one here would add a "+0 more" that never happened.
    func testListExactlyAtTheCapIsNotTruncated() {
        let names = (1...AudioDeviceDiagnostics.maximumNamedDevices).map { "Device \($0)" }
        let rendered = AudioDeviceDiagnostics.describe(names)
        XCTAssertFalse(rendered.contains("more"), rendered)
    }

    // MARK: - Change detection

    private func snapshot(
        _ inputs: [String],
        _ outputs: [String] = [],
        defaultInput: String? = nil,
        defaultOutput: String? = nil
    ) -> AudioDeviceDiagnostics.Snapshot {
        AudioDeviceDiagnostics.Snapshot(
            inputs: inputs, outputs: outputs,
            defaultInput: defaultInput, defaultOutput: defaultOutput)
    }

    func testFirstEnumerationIsAChange() {
        XCTAssertTrue(AudioDeviceDiagnostics.changed(from: nil, to: snapshot(["Built-in"])))
    }

    /// A machine with genuinely no inputs must not read as "never enumerated".
    func testNoDevicesIsDistinctFromNeverEnumerated() {
        let empty = snapshot([])
        XCTAssertTrue(
            AudioDeviceDiagnostics.changed(from: nil, to: empty),
            "the first enumeration is a change even when it finds nothing")
        XCTAssertFalse(
            AudioDeviceDiagnostics.changed(from: empty, to: empty),
            "a second enumeration finding nothing is not a change")
    }

    func testOutputOnlyChangeIsAChange() {
        XCTAssertTrue(
            AudioDeviceDiagnostics.changed(
                from: snapshot(["Mic"], ["Speakers"]),
                to: snapshot(["Mic"], ["Speakers", "Headphones"])))
    }

    /// The common case: a picker re-rendering must not emit an event.
    func testUnchangedListIsNotRecordedAgain() {
        XCTAssertFalse(
            AudioDeviceDiagnostics.changed(
                from: snapshot(["Built-in", "Jabra"]), to: snapshot(["Built-in", "Jabra"])))
    }

    func testDeviceArrivalAndDepartureAreChanges() {
        XCTAssertTrue(
            AudioDeviceDiagnostics.changed(
                from: snapshot(["Built-in"]), to: snapshot(["Built-in", "Jabra"])))
        XCTAssertTrue(
            AudioDeviceDiagnostics.changed(
                from: snapshot(["Built-in", "Jabra"]), to: snapshot(["Built-in"])))
    }

    /// Compared as an ordered list, not a set — a reordering means the
    /// system default moved, changing what "System Default" resolves to.
    func testReorderingCountsAsAChange() {
        XCTAssertTrue(
            AudioDeviceDiagnostics.changed(
                from: snapshot(["Built-in", "Jabra"]), to: snapshot(["Jabra", "Built-in"])))
    }

    // MARK: - Fields

    func testFieldsCarryAvailabilityAndSelection() {
        let fields = AudioDeviceDiagnostics.fields(
            snapshot: snapshot(["Built-in", "Jabra"], ["Built-in Output"]),
            selectedInput: "Jabra",
            selectedOutput: nil)

        XCTAssertEqual(fields["inputs"], .string("Built-in, Jabra"))
        XCTAssertEqual(fields["input_count"], .int(2))
        XCTAssertEqual(fields["outputs"], .string("Built-in Output"))
        XCTAssertEqual(fields["output_count"], .int(1))
        XCTAssertEqual(fields["selected_input"], .string("Jabra"))
    }

    /// `selected_input` alone names the choice, not the device — the record
    /// must also say which microphone "nothing" resolved to.
    func testSystemDefaultIsResolvedToARealDevice() {
        let fields = AudioDeviceDiagnostics.fields(
            snapshot: snapshot(
                ["MacBook Pro Microphone", "Jabra Evolve2 65"],
                defaultInput: "MacBook Pro Microphone"),
            selectedInput: nil,
            selectedOutput: nil)

        XCTAssertEqual(fields["selected_input"], .string("system default"))
        XCTAssertEqual(
            fields["effective_input"], .string("MacBook Pro Microphone"),
            "the bundle must name the microphone that was actually live")
    }

    func testExplicitPickIsTheEffectiveDevice() {
        let fields = AudioDeviceDiagnostics.fields(
            snapshot: snapshot(["Built-in", "Jabra"], defaultInput: "Built-in"),
            selectedInput: "Jabra",
            selectedOutput: nil)

        XCTAssertEqual(fields["selected_input"], .string("Jabra"))
        XCTAssertEqual(fields["effective_input"], .string("Jabra"))
    }

    /// An absent field would read as "nobody looked", a different answer.
    func testUnresolvableDefaultIsNamedUnknown() {
        XCTAssertEqual(
            AudioDeviceDiagnostics.effective(selected: nil, systemDefault: nil), "unknown")

        let fields = AudioDeviceDiagnostics.fields(
            snapshot: snapshot([]), selectedInput: nil, selectedOutput: nil)
        XCTAssertEqual(fields["effective_input"], .string("unknown"))
    }

    /// macOS moves the default on its own — plugging in a headset can shift
    /// what an unselected pick uses without the device lists changing at all.
    func testDefaultMovingIsAChangeEvenWhenTheListsAreIdentical() {
        let before = snapshot(["Built-in", "Jabra"], defaultInput: "Built-in")
        let after = snapshot(["Built-in", "Jabra"], defaultInput: "Jabra")

        XCTAssertEqual(before.inputs, after.inputs, "the lists are deliberately identical")
        XCTAssertTrue(
            AudioDeviceDiagnostics.changed(from: before, to: after),
            "a default that moved under the user must be recorded")
    }

    /// "System default" is spelled out rather than omitted.
    func testNoExplicitSelectionIsNamedNotOmitted() {
        let fields = AudioDeviceDiagnostics.fields(
            snapshot: snapshot(["Built-in"], ["Built-in"]),
            selectedInput: nil, selectedOutput: nil)

        XCTAssertEqual(fields["selected_input"], .string("system default"))
        XCTAssertEqual(fields["selected_output"], .string("system default"))
    }

    func testAMissingDeviceIsVisibleInTheRecord() {
        let fields = AudioDeviceDiagnostics.fields(
            snapshot: snapshot(["MacBook Pro Microphone"], ["MacBook Pro Speakers"]),
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
