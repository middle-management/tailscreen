import Foundation

/// The sharer's voice for the length of one share: the `SharerVoiceRoute` that
/// must be installed before `TailscaleScreenShareServer.start()`, the
/// `SharerVoice` built once the share is genuinely up, and the `VoiceLatch`
/// both hosts publish from. A named type so the GTK and WinUI engines don't
/// each reimplement the same start/stop/toggle ordering:
///
///   * Route installed once, before the server starts — `onAudioReceived` is
///     a bare stored var the receive thread reads with no lock.
///   * Device opened late, after `start()` returns — on Windows that spans
///     tsnet bring-up, and a lit mic indicator during login is worse than a
///     few dropped milliseconds.
///   * `onStopped` installed before `start()`, so a device dying on the way
///     up is reported rather than leaving an unmute-that-can't control.
///   * Stopping unroutes first, since the server may still be delivering.
///
/// Isolation is the caller's (GTK: main actor, WinUI: its own lock), so this
/// owns its own lock and promises nothing about which thread anything
/// arrives on; `onStateChanged` fires on whatever thread moved the latch.
public final class SharerVoiceSession: @unchecked Sendable {
    /// `isAvailable`, `isOn` — see ``VoiceLatch``. Fires only when the pair
    /// actually moved, so a host can wire this straight in without a status
    /// push per idle call.
    public var onStateChanged: ((Bool, Bool) -> Void)?

    /// The viewers' decoded voices, mixed down to one stream — one frame per
    /// 20 ms slot, everyone who spoke in it summed (`VoiceDownlink.onMixedPCM`).
    public var onRemotePCM: (([Float]) -> Void)?

    private let lock = NSLock()
    private let route = SharerVoiceRoute()
    private var voice: SharerVoice?
    private var latch = VoiceLatch()

    public init() {}

    /// Install this as the server's `onAudioReceived` before `start()`, and
    /// never again — valid for the whole session, share after share, since it
    /// routes through the long-lived route rather than a not-yet-existing voice.
    public var inboundHandler: @Sendable (Data) -> Void {
        { [route] packet in route.receive(packet) }
    }

    /// Whether a capture device is open for this share.
    public var isAvailable: Bool { lock.withLock { latch.isAvailable } }
    /// Whether the sharer's voice is reaching viewers.
    public var isOn: Bool { lock.withLock { latch.isOn } }

    /// Open the microphone and start hearing viewers, for this share only.
    /// Throws what the backend threw; both hosts treat that as "no
    /// microphone" and word it for the person rather than tearing the share down.
    ///
    /// - Parameters:
    ///   - microphone: opened by the host's own factory, keeping this free of
    ///     any platform audio dependency.
    ///   - send: hand each packet to `TailscaleScreenShareServer.sendAudioRTP`.
    public func start(
        microphone: MicrophoneCapturing,
        send: @escaping (Data) -> Void
    ) throws {
        let voice = SharerVoice(
            microphone: microphone, encoder: try OpusVoiceEncoder(), send: send)
        voice.onRemotePCM = { [weak self] pcm in self?.onRemotePCM?(pcm) }
        // Installed before `start()`: a device failing on the way up must
        // still reach the host.
        voice.onStopped = { [weak self] error in
            // Nil means the caller asked, and the caller already published.
            guard error != nil, let self else { return }
            self.publish { $0.detach() }
        }
        // Routed before the device opens, so an already-speaking viewer is heard from the first packet.
        route.setVoice(voice)
        do {
            try voice.start()
        } catch {
            // Nothing was published, but the route must not point at a dead voice.
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

    /// Flip the sharer's microphone. A no-op when no device is open.
    public func toggleMic() {
        publish { latch in
            guard case .setMuted(let muted) = latch.toggle() else { return }
            // Written under the same lock the latch moved under, so the two can't drift.
            voice?.isMuted = muted
        }
    }

    /// Move the latch under the lock, publish outside it — only if it moved.
    /// `onStateChanged` reaches a host's UI; holding the lock across that
    /// hand-off risks deadlocking against the capture thread.
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
