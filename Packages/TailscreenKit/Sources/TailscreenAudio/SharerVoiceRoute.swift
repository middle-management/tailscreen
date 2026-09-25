import Foundation

/// Where the sharer's server hands inbound viewer audio, decoupled from
/// *when* this share's `SharerVoice` comes into existence.
///
/// `TailscaleScreenShareServer.onAudioReceived` is a bare stored var read
/// from the receive thread with no lock, so it must be assigned before
/// `start()` and left alone until after `stop()` returns. This route is
/// installed once, before `start()`; the voice is published into it when
/// ready and cleared on teardown, so an early viewer packet is never dropped
/// silently.
///
/// The capture device still opens after the share is up: on Windows
/// `start()` includes tsnet bring-up, and a mic indicator lit through an
/// interactive browser login is worse than a few dropped milliseconds.
public final class SharerVoiceRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var voice: SharerVoice?

    public init() {}

    /// Publish the voice inbound packets are handed to, or nil to stop
    /// routing. Called from the host's own thread; `receive` is not.
    public func setVoice(_ voice: SharerVoice?) {
        lock.withLock { self.voice = voice }
    }

    /// Route one inbound audio datagram, on the server's receive thread. A
    /// packet arriving before a voice exists is dropped; one arriving after is not.
    public func receive(_ packet: Data) {
        guard let voice = lock.withLock({ self.voice }) else { return }
        voice.receive(packet)
    }
}
