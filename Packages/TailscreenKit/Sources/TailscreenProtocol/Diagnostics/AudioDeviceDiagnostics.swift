import Foundation

/// Rendering and change-detection for the audio devices a session had to
/// choose from.
///
/// ## Why the available list matters, not just the chosen one
///
/// "They couldn't hear me" has two completely different causes that look
/// identical from the outside:
///
///   * The headset **was** in the list and the wrong one was selected — the
///     built-in mic was live and picked up nothing useful.
///   * The headset **was never in the list** at all: not enumerated, so not
///     selectable, so the pick could never have been right. That is a driver,
///     permission or hot-plug problem, and no amount of clicking in
///     Tailscreen would have fixed it.
///
/// Recording only the selected device answers the first and is silent on the
/// second, which is the one people actually get stuck on. So both go in.
///
/// ## Why changes, not polls
///
/// The host enumerates devices whenever a picker is about to render, which can
/// be many times a session and almost always returns the same answer. Emitting
/// an event per enumeration would bury the session in identical lines.
///
/// Emitting on *change* is both quieter and strictly more informative: a device
/// appearing or vanishing mid-session is itself the bug in a good number of
/// these reports — a Bluetooth headset dropping out is invisible to the user
/// beyond "it stopped working", and a line saying the device left is the whole
/// diagnosis.
public enum AudioDeviceDiagnostics {

    /// The most devices named in one event.
    ///
    /// A machine in a studio can enumerate dozens of channels of an interface,
    /// and a single event that is four kilobytes of device names would push the
    /// rest of the session out of the buffer. Past the cap the names stop and
    /// the count continues, which keeps the important part — how many there
    /// were — exact.
    public static let maximumNamedDevices = 12

    /// Render a device list as one stable field value:
    /// `"MacBook Pro Microphone, Jabra Evolve2 65"`, or `"none"`.
    ///
    /// Order is preserved rather than sorted: the host enumerates in the order
    /// the pickers show, and a reader comparing a bundle against a screenshot
    /// of the picker should see the same sequence.
    public static func describe(_ names: [String]) -> String {
        guard !names.isEmpty else { return "none" }
        guard names.count > maximumNamedDevices else { return names.joined(separator: ", ") }
        let shown = names.prefix(maximumNamedDevices).joined(separator: ", ")
        return "\(shown), +\(names.count - maximumNamedDevices) more"
    }

    /// One enumeration of the machine's audio devices.
    ///
    /// A named type rather than a pair of arrays because the host has to hold
    /// the previous one to compare against, and "not enumerated yet" is a real
    /// state that needs somewhere to live. As an optional *struct* it has a
    /// name; as an optional *array* it would have been an empty-versus-absent
    /// ambiguity of exactly the kind swiftlint's `discouraged_optional_collection`
    /// exists to prevent — and the ambiguity is real here, since a machine
    /// with genuinely no inputs is a thing that happens and is worth recording.
    public struct Snapshot: Equatable, Sendable {
        public var inputs: [String]
        public var outputs: [String]

        /// What the system default resolves to right now, by name.
        ///
        /// Part of the snapshot, and therefore part of change detection, on
        /// purpose. **The default moves on its own.** Plugging in a headset
        /// makes it the default; unplugging it hands the session back to the
        /// built-in mic; changing it in System Settings moves it with no
        /// device arriving or leaving at all. Someone who never touched
        /// Tailscreen's picker is on whatever the default is *at that moment*,
        /// so a default that shifts mid-session changes what the share records
        /// from — silently, and with nothing in the device lists to show it.
        /// That is exactly the kind of invisible change worth an event.
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

    /// Whether the device list changed in a way worth recording.
    ///
    /// Compares as an ordered list, not a set: a reordering means the system
    /// default moved, which changes what an unselected ("System Default") pick
    /// resolves to — a real change in what the session is recording from, and
    /// exactly the kind that otherwise goes unexplained.
    public static func changed(from previous: Snapshot?, to current: Snapshot) -> Bool {
        guard let previous else {
            // Nothing recorded yet: the first enumeration is the baseline, and
            // is always worth one event.
            return true
        }
        return previous != current
    }

    /// The fields for an `audio.devices.changed` event.
    ///
    /// Counts alongside the names so a truncated list still answers "how many
    /// were there", and the two are always consistent because they come from
    /// one place.
    /// **`selected_*` and `effective_*` both appear, and they answer different
    /// questions.** `selected` is what the user chose — possibly "system
    /// default", meaning they chose nothing. `effective` is the device that
    /// choice actually resolves to. A reader chasing "they couldn't hear me"
    /// wants the second; one asking "did they pick the wrong one" wants the
    /// first; and the case that costs the most time is `selected` reading
    /// "system default" while `effective` is not the device the person
    /// assumed — which neither field answers on its own.
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
            // "system default" rather than an absent field: the user made no
            // explicit pick, which is a real state and a common answer to
            // "why was it using the built-in mic".
            "selected_input": .string(selectedInput ?? "system default"),
            "selected_output": .string(selectedOutput ?? "system default"),
            "effective_input": .string(
                effective(selected: selectedInput, systemDefault: snapshot.defaultInput)),
            "effective_output": .string(
                effective(selected: selectedOutput, systemDefault: snapshot.defaultOutput))
        ]
    }

    /// The device actually in use: the explicit pick if there was one, else
    /// whatever the system default currently resolves to.
    ///
    /// `"unknown"` when there is no explicit pick and the default could not be
    /// resolved — a real outcome (no input devices at all, a HAL query that
    /// failed) and worth naming rather than leaving the field absent, because
    /// "we could not tell" and "nobody looked" are different answers.
    public static func effective(selected: String?, systemDefault: String?) -> String {
        selected ?? systemDefault ?? "unknown"
    }
}
