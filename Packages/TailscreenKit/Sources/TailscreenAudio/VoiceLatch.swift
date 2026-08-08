/// The two flags every microphone control in this repo publishes, and the four
/// transitions that are allowed to move them.
///
/// `isAvailable` is a CAPABILITY — a capture device was opened for this session
/// — and `isOn` is whether the person is actually on the air. Every host draws
/// its mic control from the pair: absent when unavailable, off/on otherwise.
/// The pair is small enough that five places wrote it inline (the GTK viewer's
/// `VoiceControls`, the WinUI viewer's model, and both share engines' voice
/// blocks), and all five had to agree about three things that are easy to get
/// subtly different and impossible to see when they are wrong:
///
///   * **Attaching never puts somebody on the air.** A share or a session that
///     started hot would be a person talking into a call they did not know was
///     live.
///   * **A toggle with nothing attached moves nothing.** The hosts spell this
///     `guard let uplink else { return }` — and two of them guarded on the
///     *uplink* while publishing the *flags*, so a device that had already
///     failed (uplink still held, `isAvailable` already false) could still be
///     toggled into `isOn == true`. That is a live-microphone indicator over a
///     device recording nothing: the one wrong answer a mute control can give,
///     and the exact thing every other line in this area exists to avoid.
///   * **A failure clears both flags together**, for the same reason.
///
/// A value type with no reference to an uplink, so the transition and the write
/// to `VoiceUplink.isMuted` cannot disagree: `toggle()` hands back the value to
/// write, rather than each host deriving it from the flag it just set.
public struct VoiceLatch: Equatable, Sendable {
    /// What a press did, and therefore what the host owes its uplink.
    public enum ToggleOutcome: Equatable, Sendable {
        /// Nothing is attached, so nothing moved — and the host must not touch
        /// its uplink either. A case rather than a nil `Bool` because "do
        /// nothing" and "mute" are the two answers most easily confused here,
        /// and confusing them is how a released device gets toggled back on.
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
    /// - Returns: the value to write to the uplink's `isMuted` — `true`. Handed
    ///   back rather than assumed so the host mirrors the latch instead of
    ///   asserting a default the latch might one day change.
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

    /// The session ended, or the device went away mid-session.
    ///
    /// One transition for both, deliberately: they publish the same pair, and a
    /// separate `fail()` that happened to set only one flag is precisely the
    /// bug this type exists to make unrepresentable. What differs between them
    /// — a sentence for the person — is the host's, not the latch's.
    public mutating func detach() {
        isAvailable = false
        isOn = false
    }
}
