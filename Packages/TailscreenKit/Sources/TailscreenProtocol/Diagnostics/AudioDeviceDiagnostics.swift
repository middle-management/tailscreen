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

    /// Whether the device list changed in a way worth recording.
    ///
    /// Compares as an ordered list, not a set: a reordering means the system
    /// default moved, which changes what an unselected ("System Default") pick
    /// resolves to — a real change in what the session is recording from, and
    /// exactly the kind that otherwise goes unexplained.
    public static func changed(from previous: [String]?, to current: [String]) -> Bool {
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
    public static func fields(
        inputs: [String],
        outputs: [String],
        selectedInput: String?,
        selectedOutput: String?
    ) -> [String: DiagnosticValue] {
        [
            "inputs": .string(describe(inputs)),
            "input_count": DiagnosticValue(inputs.count),
            "outputs": .string(describe(outputs)),
            "output_count": DiagnosticValue(outputs.count),
            // "system default" rather than an absent field: the user made no
            // explicit pick, which is a real state and a common answer to
            // "why was it using the built-in mic".
            "selected_input": .string(selectedInput ?? "system default"),
            "selected_output": .string(selectedOutput ?? "system default")
        ]
    }
}
