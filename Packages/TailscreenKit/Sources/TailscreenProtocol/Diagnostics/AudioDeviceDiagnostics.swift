import Foundation

/// Rendering and change-detection for the audio devices a session had to
/// choose from. Records both the available list and the selected device,
/// since "they couldn't hear me" can mean either the wrong device was picked
/// or the right one was never enumerated at all (driver/permission/hot-plug).
///
/// Emits on change, not on every enumeration (which happens whenever a
/// picker renders) — a device appearing or vanishing mid-session is itself
/// the bug in a good number of reports.
public enum AudioDeviceDiagnostics {

    /// The most devices named in one event, so a studio interface's dozens
    /// of channels don't push the rest of the session out of the buffer.
    /// Past the cap, names stop but the count stays exact.
    public static let maximumNamedDevices = 12

    /// Render a device list as one stable field value:
    /// `"MacBook Pro Microphone, Jabra Evolve2 65"`, or `"none"`. Order
    /// preserved, not sorted, matching the picker's own order.
    public static func describe(_ names: [String]) -> String {
        guard !names.isEmpty else { return "none" }
        guard names.count > maximumNamedDevices else { return names.joined(separator: ", ") }
        let shown = names.prefix(maximumNamedDevices).joined(separator: ", ")
        return "\(shown), +\(names.count - maximumNamedDevices) more"
    }

    /// One enumeration of the machine's audio devices. A named type, not a
    /// pair of arrays, so "not enumerated yet" (nil) is distinct from
    /// "enumerated, found none" (empty arrays) — both real states.
    public struct Snapshot: Equatable, Sendable {
        public var inputs: [String]
        public var outputs: [String]

        /// What the system default resolves to right now, by name. Part of
        /// the snapshot and its change detection: the default moves on its
        /// own (headset plug-in, System Settings), silently changing what an
        /// unselected pick records from.
        public var defaultInput: String?
        public var defaultOutput: String?

        public init(
            inputs: [String],
            outputs: [String],
            defaultInput: String? = nil,
            defaultOutput: String? = nil
        ) {
            self.inputs = inputs
            self.outputs = outputs
            self.defaultInput = defaultInput
            self.defaultOutput = defaultOutput
        }
    }

    /// Whether the device list changed in a way worth recording. Compares as
    /// an ordered list, not a set — reordering means the system default moved.
    public static func changed(from previous: Snapshot?, to current: Snapshot) -> Bool {
        guard let previous else {
            // Nothing recorded yet: the first enumeration is always worth one event.
            return true
        }
        return previous != current
    }

    /// The fields for an `audio.devices.changed` event. `selected_*`
    /// (what the user chose, possibly "system default") and `effective_*`
    /// (what that resolves to) both appear, since the interesting case is
    /// exactly when they diverge.
    public static func fields(
        snapshot: Snapshot,
        selectedInput: String?,
        selectedOutput: String?
    ) -> [String: DiagnosticValue] {
        [
            "inputs": .string(describe(snapshot.inputs)),
            "input_count": DiagnosticValue(snapshot.inputs.count),
            "outputs": .string(describe(snapshot.outputs)),
            "output_count": DiagnosticValue(snapshot.outputs.count),
            // "system default", not an absent field: no explicit pick is a real state.
            "selected_input": .string(selectedInput ?? "system default"),
            "selected_output": .string(selectedOutput ?? "system default"),
            "effective_input": .string(
                effective(selected: selectedInput, systemDefault: snapshot.defaultInput)),
            "effective_output": .string(
                effective(selected: selectedOutput, systemDefault: snapshot.defaultOutput))
        ]
    }

    /// The device actually in use: the explicit pick, else the system
    /// default. `"unknown"` when neither resolved — a real outcome worth
    /// naming rather than an absent field.
    public static func effective(selected: String?, systemDefault: String?) -> String {
        selected ?? systemDefault ?? "unknown"
    }
}
