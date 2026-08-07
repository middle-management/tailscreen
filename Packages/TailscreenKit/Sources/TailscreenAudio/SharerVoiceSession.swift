import Foundation

/// The sharer's voice for the length of one share: the `SharerVoiceRoute` that
/// must be installed before `TailscaleScreenShareServer.start()`, the
/// `SharerVoice` that is built only once the share is genuinely up, and the
/// `VoiceLatch` both hosts publish from.
///
/// A named type because the GTK and WinUI share engines each wrote the same
/// start/stop/toggle triple and the ORDER inside it is the whole of the
/// correctness. Four rules, each of which one of the two hosts had already got
/// almost right:
///
///   * The **route is installed once, before the server starts** — the server's
///     callbacks are bare stored vars its receive thread reads with no lock, so
///     `onAudioReceived` must never be reassigned on a running share. Hosts
///     install ``inboundHandler`` and never touch it again.
///   * The **device is opened late**, after `start()` returns. On Windows that
///     await spans tsnet bring-up, and a microphone indicator lit through an
///     interactive browser login is far worse than a few dropped milliseconds.
///   * **`onStopped` is installed before `start()`**, so a device that dies on
///     the way up is reported rather than silently leaving a mic control that
///     cannot unmute. The Windows engine installed it after, which left a
///     window — small, but exactly the one a refused device lands in.
///   * **Stopping unroutes first.** The server may still be delivering, and a
///     packet handed to a voice being torn down is the race `VoiceDownlink`'s
///     lock exists for; the cheap answer is to stop reaching it at all.
///
/// Isolation is deliberately the caller's: the GTK engine holds this from the
/// main actor and the Windows one from behind its own lock, so this owns a lock
/// of its own and promises nothing about which thread anything arrives on.
/// `onStateChanged` therefore fires on whatever thread moved the latch — the
/// host hops if its UI needs it to.
public final class SharerVoiceSession: @unchecked Sendable {
    /// `isAvailable`, `isOn` — see ``VoiceLatch``. Fired only when the pair
    /// actually MOVED: a toggle with no device open, or a second `stop()`,
    /// publishes nothing, so a host can wire this straight into whatever
    /// re-renders without a status push per idle call.
    public var onStateChanged: ((Bool, Bool) -> Void)?

    /// A viewer's decoded voice, already mixed down to one stream.
    ///
    /// The SSRC is dropped on the way through: there is one local output
    /// device and what a person hears is the mix. A sharer UI that wanted a
    /// speaking indicator would take `SharerVoice.onRemotePCM` instead.
    public var onRemotePCM: (([Float]) -> Void)?

    private let lock = NSLock()
    private let route = SharerVoiceRoute()
    private var voice: SharerVoice?
    private var latch = VoiceLatch()

    public init() {}

    /// Install this as the server's `onAudioReceived` **before `start()`**, and
    /// never again. It is valid for the whole life of this session, share after
    /// share, precisely because it routes through the long-lived route rather
    /// than capturing a voice that does not exist yet.
    public var inboundHandler: @Sendable (Data) -> Void {
        { [route] packet in route.receive(packet) }
    }

    /// Whether a capture device is open for this share.
    public var isAvailable: Bool { lock.withLock { latch.isAvailable } }
    /// Whether the sharer's voice is reaching viewers.
    public var isOn: Bool { lock.withLock { latch.isOn } }

    /// Open the microphone and start hearing viewers, for this share only.
    ///
    /// Throws what the backend threw. Both hosts treat that as "no microphone"
    /// and word it for the person rather than tearing the share down — a
    /// machine with no capture device shares perfectly well.
    ///
    /// - Parameters:
    ///   - microphone: opened by the host's own factory, so this stays free of
    ///     any platform audio dependency.
    ///   - send: hand each packet to `TailscaleScreenShareServer.sendAudioRTP`.
    public func start(
        microphone: MicrophoneCapturing,
        send: @escaping (Data) -> Void
    ) throws {
        let voice = SharerVoice(
            microphone: microphone, encoder: try OpusVoiceEncoder(), send: send)
        voice.onRemotePCM = { [weak self] _, pcm in self?.onRemotePCM?(pcm) }
        // Installed BEFORE `start()`: a device that fails on the way up must
        // reach the host, or the mic control stays offering an unmute that
        // cannot happen.
        voice.onStopped = { [weak self] error in
            // Nil means the caller asked, and the caller already published.
            guard error != nil, let self else { return }
            self.publish { $0.detach() }
        }
        // Routed before the device opens, so a viewer already speaking is heard
        // from the first packet rather than from the first packet after this
        // returns.
        route.setVoice(voice)
        do {
            try voice.start()
        } catch {
            // Nothing was published, so nothing has to be unpublished — but the
            // route must not be left pointing at a voice that never ran.
            route.setVoice(nil)
            throw error
        }
        lock.withLock { self.voice = voice }
        publish { $0.attach() }
    }

    /// Release the device and stop hearing viewers. Idempotent.
    public func stop() {
        // Unroute FIRST — see the type comment.
        route.setVoice(nil)
        let live = lock.withLock { () -> SharerVoice? in
            let value = voice
            voice = nil
            return value
        }
        live?.stop()
        publish { $0.detach() }
    }

    /// Flip the sharer's microphone. A no-op when no device is open, which is
    /// also when no host draws the control.
    public func toggleMic() {
        publish { latch in
            guard case .setMuted(let muted) = latch.toggle() else { return }
            // Written under the same lock the latch moved under, so the flag
            // the host publishes and the value the pipeline drops on can never
            // describe two different presses.
            voice?.isMuted = muted
        }
    }

    /// Move the latch under the lock, publish outside it — and only if it
    /// moved.
    ///
    /// Outside on purpose: `onStateChanged` reaches a host's UI, and holding a
    /// lock across that hand-off is how a UI callback ends up deadlocking
    /// against the capture thread that reported the device gone.
    private func publish(_ body: (inout VoiceLatch) -> Void) {
        let state: (Bool, Bool)? = lock.withLock {
            let before = latch
            body(&latch)
            guard latch != before else { return nil }
            return (latch.isAvailable, latch.isOn)
        }
        guard let state else { return }
        onStateChanged?(state.0, state.1)
    }
}
