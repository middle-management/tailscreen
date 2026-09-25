/// The two flags every microphone control in this repo publishes, and the
/// four transitions allowed to move them. `isAvailable` is a capability (a
/// device was opened this session); `isOn` is whether the person is actually
/// on the air.
///
/// Rules every host must get right together:
///   * Attaching never puts somebody on the air.
///   * A toggle with nothing attached moves nothing — guarding on the uplink
///     while publishing the flags separately can toggle `isOn` true over a
///     device that already failed.
///   * A failure clears both flags together.
///
/// A value type with no reference to an uplink, so the transition and the
/// write to `VoiceUplink.isMuted` can't disagree: `toggle()` hands back the
/// value to write.
public struct VoiceLatch: Equatable, Sendable {
    /// What a press did, and therefore what the host owes its uplink.
    public enum ToggleOutcome: Equatable, Sendable {
        /// Nothing attached, nothing moved. A case, not a nil `Bool` — "do
        /// nothing" and "mute" are easy to confuse, and confusing them
        /// toggles a released device back on.
        case unchanged
        /// Write this to the uplink's `isMuted`.
        case setMuted(Bool)
    }

    /// Whether a capture device is open for this session.
    public private(set) var isAvailable: Bool = false
    /// Whether the microphone is reaching the far end. Never true while
    /// `isAvailable` is false — that pairing is this type's whole job.
    public private(set) var isOn: Bool = false

    public init() {}

    /// A device was opened. Starts muted, always.
    ///
    /// - Returns: the value to write to the uplink's `isMuted` — handed back
    ///   so the host mirrors the latch rather than asserting a default.
    @discardableResult
    public mutating func attach() -> Bool {
        isAvailable = true
        isOn = false
        return true
    }

    /// Flip the microphone.
    ///
    /// - Returns: `.setMuted` with the value to write to the uplink's
    ///   `isMuted`, or `.unchanged` when nothing is attached — in which case
    ///   nothing moved at all.
    public mutating func toggle() -> ToggleOutcome {
        guard isAvailable else { return .unchanged }
        isOn.toggle()
        return .setMuted(!isOn)
    }

    /// The session ended, or the device went away mid-session. One
    /// transition for both, deliberately — they publish the same pair. What
    /// differs (the sentence for the person) is the host's, not the latch's.
    public mutating func detach() {
        isAvailable = false
        isOn = false
    }
}
