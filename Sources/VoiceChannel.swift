import Foundation

/// Process-side voice pipeline: PCM in → AAC enc → RTP out, and RTP in →
/// AAC dec (per SSRC) → mixed PCM out. Hardware capture/playback glue is
/// in `MicCapture` (added in Task 7) which feeds this class.
///
/// Thread-safe via an internal serial queue: capture callbacks (audio
/// thread) and network callbacks (TailscaleKit reader task) call into
/// public methods which dispatch onto the queue. State only mutates on
/// the queue.
///
/// Marked `@unchecked Sendable`: all stored mutable state (`_isMuted`,
/// `decoders`, `brokenSSRCs`) is touched only from `queue`. `onMixedPCM`
/// is the documented exception — set it once before any `receive(_:)`.
final class VoiceChannel: @unchecked Sendable {
    let localSSRC: UInt32
    var isMuted: Bool {
        get { queue.sync { _isMuted } }
        set { queue.sync { _isMuted = newValue } }
    }

    /// Invoked on the internal queue every time the encoder produces an
    /// RTP packet. Caller should pass it to the network layer.
    private let onSend: (Data) -> Void

    /// Invoked on the internal queue when the decoder produces a block of
    /// PCM samples for one inbound RTP audio packet. One call per packet
    /// per remote SSRC — mixing across peers is the caller's job (the
    /// audio engine in `MicCapture` schedules them into a shared player).
    ///
    /// Set this once before the first `receive(_:)` call. Mutating it
    /// concurrently with packet ingestion is unsafe; the queue reads it
    /// without synchronization.
    var onMixedPCM: (([Float]) -> Void)?

    private let queue = DispatchQueue(label: "VoiceChannel")
    private var _isMuted: Bool = true
    private let encoder: AACEncoder
    private let packetizer: AudioRTPPacketizer
    private let depacketizer = AudioRTPDepacketizer()
    private var decoders: [UInt32: AACDecoder] = [:]
    private var brokenSSRCs: Set<UInt32> = []
    private var sentCount: Int = 0
    private var recvCount: Int = 0
    private var playedCount: Int = 0

    init(localSSRC: UInt32, onSend: @escaping (Data) -> Void) throws {
        self.localSSRC = localSSRC
        self.onSend = onSend
        self.encoder = try AACEncoder()
        self.packetizer = AudioRTPPacketizer(ssrc: localSSRC)
    }

    /// Push exactly 1024 PCM samples (one AAC AU's worth) for outbound
    /// transmission. No-op when muted.
    func processOutboundFrame(_ pcm: [Float]) {
        queue.async {
            guard !self._isMuted else { return }
            do {
                guard let au = try self.encoder.encode(pcm: pcm) else { return }
                let packet = self.packetizer.packetize(au: au)
                self.sentCount += 1
                if self.sentCount == 1 || self.sentCount % 50 == 0 {
                    print("VoiceChannel[ssrc=\(self.localSSRC)]: sent #\(self.sentCount) (\(packet.count) bytes)")
                }
                self.onSend(packet)
            } catch {
                print("VoiceChannel: encode failed: \(error)")
            }
        }
    }

    /// Ingest one inbound RTP audio packet. Decodes per SSRC and emits
    /// PCM via `onMixedPCM`.
    func receive(_ packet: Data) {
        queue.async {
            guard let parsed = self.depacketizer.unpack(packet) else { return }
            self.recvCount += 1
            if self.recvCount == 1 || self.recvCount % 50 == 0 {
                print("VoiceChannel[ssrc=\(self.localSSRC)]: recv #\(self.recvCount) from ssrc=\(parsed.ssrc) (\(parsed.au.count) bytes)")
            }
            // Drop our own loopback if the network somehow returned it.
            guard parsed.ssrc != self.localSSRC else { return }
            guard !self.brokenSSRCs.contains(parsed.ssrc) else { return }
            do {
                let decoder = try self.ensureDecoder(for: parsed.ssrc)
                let samples = try decoder.decode(au: parsed.au)
                if !samples.isEmpty {
                    self.playedCount += 1
                    if self.playedCount == 1 || self.playedCount % 50 == 0 {
                        print("VoiceChannel[ssrc=\(self.localSSRC)]: decoded #\(self.playedCount) from ssrc=\(parsed.ssrc) (\(samples.count) samples, mixedPCM=\(self.onMixedPCM != nil ? "wired" : "nil"))")
                    }
                    self.onMixedPCM?(samples)
                }
            } catch {
                if self.decoders[parsed.ssrc] == nil {
                    // Decoder init failed for this SSRC — blacklist so we
                    // don't spam stderr at 50 Hz.
                    self.brokenSSRCs.insert(parsed.ssrc)
                    print("VoiceChannel: decoder init failed for ssrc=\(parsed.ssrc): \(error). Dropping further packets from this SSRC.")
                } else {
                    // Decode (not init) failed — log once per packet but
                    // keep the decoder; transient corruption is normal.
                    print("VoiceChannel: decode failed for ssrc=\(parsed.ssrc): \(error)")
                }
            }
        }
    }

    /// Forget all per-SSRC decoders. Called when the share session ends
    /// so a future session starts fresh.
    func reset() {
        queue.async {
            self.decoders.removeAll()
            self.brokenSSRCs.removeAll()
        }
    }

    private func ensureDecoder(for ssrc: UInt32) throws -> AACDecoder {
        if let existing = decoders[ssrc] { return existing }
        let new = try AACDecoder()
        decoders[ssrc] = new
        return new
    }

#if DEBUG
    /// Drain the internal queue so test assertions can run synchronously
    /// after enqueuing outbound/inbound work.
    internal func flushForTesting() {
        queue.sync { }
    }
#endif
}

import AVFoundation

/// AVAudioEngine glue: input from VoiceProcessingIO mic (with built-in
/// AEC), output through the same VPIO unit (so AEC has the right
/// reference signal). Feeds inbound PCM frames into the VoiceChannel
/// and renders outbound PCM blocks the channel decoded from RTP.
/// Drains the AVAudioEngine input tap on the audio render thread and feeds
/// 1024-sample frames into the VoiceChannel. Lives outside `@MainActor`
/// because installTap fires on AVAudioEngine's serialized real-time queue;
/// hopping every callback to `@MainActor` (a) drops Swift 6 isolation
/// assertions, and (b) introduces unacceptable latency at 50 Hz.
///
/// All state is touched only from the tap callback, which AVAudioEngine
/// serializes — `@unchecked Sendable` is sound under that contract.
private final class TapBuffer: @unchecked Sendable {
    private let channel: VoiceChannel
    private var accumulator: [Float] = []
    private let converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let sourceSampleRate: Double

    var usesConverter: Bool { converter != nil }

    init?(channel: VoiceChannel, sourceFormat: AVAudioFormat) {
        self.channel = channel
        self.sourceSampleRate = sourceFormat.sampleRate
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ) else { return nil }
        self.targetFormat = target

        if sourceFormat.sampleRate == 48_000 && sourceFormat.channelCount == 1
            && sourceFormat.commonFormat == .pcmFormatFloat32 {
            // Already in target format; skip the converter.
            self.converter = nil
        } else {
            guard let conv = AVAudioConverter(from: sourceFormat, to: target) else {
                print("MicCapture: AVAudioConverter init failed for \(sourceFormat) → \(target)")
                return nil
            }
            self.converter = conv
        }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        // Fast path: input already 48 kHz mono Float32.
        if converter == nil {
            guard let cd = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: cd, count: frameCount))
            appendAndDrain(samples)
            return
        }

        guard let converter = converter else { return }

        // Output capacity: input frames scaled by sample-rate ratio + slack
        // for converter buffering.
        let ratio = 48_000.0 / sourceSampleRate
        let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard outCap > 0,
              let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap)
        else { return }

        final class OneShot: @unchecked Sendable {
            var done = false
            var buffer: AVAudioPCMBuffer?
        }
        let flag = OneShot()
        flag.buffer = buffer
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { [flag] _, statusOut in
            if flag.done {
                statusOut.pointee = .endOfStream
                return nil
            }
            flag.done = true
            statusOut.pointee = .haveData
            return flag.buffer
        }
        let status = converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
        if status == .error {
            print("MicCapture: AVAudioConverter convert failed: \(error?.localizedDescription ?? "unknown")")
            return
        }
        guard let cd = outBuf.floatChannelData?[0] else { return }
        let frameCount = Int(outBuf.frameLength)
        guard frameCount > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: cd, count: frameCount))
        appendAndDrain(samples)
    }

    private func appendAndDrain(_ samples: [Float]) {
        accumulator.append(contentsOf: samples)
        while accumulator.count >= 1024 {
            let frame = Array(accumulator.prefix(1024))
            accumulator.removeFirst(1024)
            channel.processOutboundFrame(frame)
        }
    }
}

@MainActor
final class MicCapture {
    private let channel: VoiceChannel
    private let engine = AVAudioEngine()
    private var playerNodes: [AVAudioPlayerNode] = []
    private let mixer: AVAudioMixerNode
    private let outputFormat: AVAudioFormat
    private var tapBuffer: TapBuffer?
    private var isPlaying = false
    private(set) var isCapturing = false

    init(channel: VoiceChannel) {
        self.channel = channel
        self.mixer = engine.mainMixerNode
        // 48 kHz mono Float32 — matches the codec format.
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!

        // Pipe decoded PCM (per-SSRC mix already done by VoiceChannel)
        // into a player node so the user hears it.
        channel.onMixedPCM = { [weak self] samples in
            Task { @MainActor [weak self] in self?.scheduleSamples(samples) }
        }
    }

    /// Start the playback half of the engine. Builds the player → mixer →
    /// output graph and starts the engine without touching the input node,
    /// so listening works without prompting for microphone permission.
    func startPlayback() throws {
        guard !isPlaying else { return }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: mixer, format: outputFormat)
        playerNodes.append(player)
        try engine.start()
        player.play()
        isPlaying = true
        print("MicCapture: playback engine started (output-only, no mic).")
    }

    /// Enable microphone capture. Requests permission, restarts the engine
    /// with VoiceProcessingIO enabled (for hardware AEC), and installs the
    /// input tap. Throws if permission is denied or the engine reconfigure
    /// fails.
    func enableCapture() async throws {
        guard !isCapturing else { return }
        let granted = await Self.requestMicPermission()
        guard granted else {
            throw NSError(
                domain: "Tailscreen.VoiceChannel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]
            )
        }

        // setVoiceProcessingEnabled requires the engine to be stopped.
        if isPlaying { engine.stop() }
        try? engine.inputNode.setVoiceProcessingEnabled(true)
        try? engine.outputNode.setVoiceProcessingEnabled(true)

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard let buffer = TapBuffer(channel: channel, sourceFormat: inputFormat) else {
            // Try to restart playback even if capture setup fails.
            try? engine.start()
            for player in playerNodes { player.play() }
            throw NSError(
                domain: "Tailscreen.VoiceChannel",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not configure audio converter for \(inputFormat)"]
            )
        }
        self.tapBuffer = buffer
        print("MicCapture: enabling capture, input \(inputFormat) → 48 kHz mono Float32 (converter=\(buffer.usesConverter))")
        Self.installTap(on: engine.inputNode, format: inputFormat, buffer: buffer)

        try engine.start()
        for player in playerNodes { player.play() }
        isCapturing = true
    }

    /// Disable microphone capture. Removes the tap; engine stays running
    /// for playback.
    func disableCapture() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapBuffer = nil
        isCapturing = false
        print("MicCapture: capture disabled.")
    }

    func stop() {
        if isCapturing {
            engine.inputNode.removeTap(onBus: 0)
            tapBuffer = nil
            isCapturing = false
        }
        if isPlaying {
            for node in playerNodes { node.stop() }
            engine.stop()
            playerNodes.removeAll()
            isPlaying = false
        }
    }

    /// Install the input tap from a nonisolated context so the closure
    /// AVAudioEngine retains does not inherit `@MainActor` isolation from
    /// `start()`. Without this, the audio render thread invoking the tap
    /// trips Swift 6's `dispatch_assert_queue` check (SIGTRAP) on the very
    /// first buffer.
    nonisolated private static func installTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        buffer: TapBuffer
    ) {
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format
        ) { avBuffer, _ in
            buffer.process(avBuffer)
        }
    }

    private var scheduledCount: Int = 0

    private func scheduleSamples(_ samples: [Float]) {
        guard isPlaying, let player = playerNodes.first else {
            print("MicCapture: scheduleSamples drop — isPlaying=\(isPlaying), players=\(playerNodes.count)")
            return
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let dst = buffer.floatChannelData?[0] else { return }
        var peak: Float = 0
        for (i, sample) in samples.enumerated() {
            dst[i] = sample
            let abs = sample < 0 ? -sample : sample
            if abs > peak { peak = abs }
        }
        scheduledCount += 1
        if scheduledCount == 1 || scheduledCount % 50 == 0 {
            print("MicCapture: scheduled #\(scheduledCount) (\(samples.count) frames, peak=\(peak), playerPlaying=\(player.isPlaying), engineRunning=\(engine.isRunning))")
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    private static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }
}
