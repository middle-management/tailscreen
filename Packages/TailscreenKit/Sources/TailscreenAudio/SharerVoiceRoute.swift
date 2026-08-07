import Foundation

/// Where the sharer's server hands inbound viewer audio, decoupled from *when*
/// this share's `SharerVoice` comes into existence.
///
/// It exists because of `TailscaleScreenShareServer`'s callback contract:
/// `onAudioReceived` and its siblings are bare stored vars read from the
/// receive thread with no lock, so they must be **assigned before `start()`
/// and left alone until after `stop()` returns**. Both swift-cross-ui sharer
/// hosts used to assign `onAudioReceived` from `startVoice`, which runs after
/// `start()` — a data race on the property itself, and, more visibly, every
/// viewer packet that arrived while the capture device was still opening went
/// on the floor with nothing anywhere saying so.
///
/// The route is installed once, before `start()`. The voice is published into
/// it when it is ready and cleared on teardown. The capture device is still
/// opened after the share is up, deliberately: on Windows `start()` includes
/// tsnet bring-up, and a microphone indicator lit through an interactive
/// browser login is a far worse answer than a few dropped milliseconds.
/// (macOS does not need this — it builds its `VoiceChannel` before `start()`
/// because its playback and capture halves open separately.)
public final class SharerVoiceRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var voice: SharerVoice?

    public init() {}

    /// Publish the voice inbound packets are handed to, or nil to stop
    /// routing. Called from the host's own thread; `receive` is not.
    public func setVoice(_ voice: SharerVoice?) {
        lock.withLock { self.voice = voice }
    }

    /// Route one inbound audio datagram, on the server's receive thread.
    ///
    /// A packet that arrives before a voice exists is dropped — the only
    /// thing it could be — but one that arrives after is not, which is the
    /// whole point of installing this before `start()`.
    public func receive(_ packet: Data) {
        guard let voice = lock.withLock({ self.voice }) else { return }
        voice.receive(packet)
    }
}
