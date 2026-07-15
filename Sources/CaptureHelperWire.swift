import Foundation

/// Framed binary protocol between the Tailscreen main process and
/// its `--capture-helper` child. Designed for one-way streaming on
/// each pipe:
///
///   - **stdout** (helper → main): video frames + lifecycle signals.
///   - **stdin** (main → helper): control messages.
///
/// Frame layout (both directions):
///
///     [type:1 byte][len:4 bytes BE][payload:N bytes]
///
/// All numeric fields are big-endian. The 1-byte type makes a
/// stray byte in the stream easy to resync from (we just discard
/// until the next valid type).
enum CaptureHelperWire {
    /// Helper → main message types.
    enum OutType: UInt8 {
        /// Encoded H.264/HEVC access unit. Payload is AVCC-framed.
        case accessUnit = 0x01
        /// `[1 byte codec:0=H264 1=HEVC][4 bytes width BE][4 bytes height BE]
        /// [4 bytes paramSetCount BE]` followed by `paramSetCount`
        /// length-prefixed parameter set NAL units. Sent once per
        /// codec config change so main has SPS/PPS or VPS/SPS/PPS to
        /// stuff into RTP keyframes.
        case parameterSets = 0x02
        /// Helper has finished bringing up the SCStream and just
        /// delivered its first sample. Payload empty. Drives the
        /// main app's "first preview" gate without scraping logs.
        case firstFrame = 0x03
        /// Downsampled JPEG of the most recent captured frame for the
        /// SharingCard's thumbnail. Payload = raw JPEG bytes
        /// (~280 px wide). Helper emits roughly once per second; we
        /// don't need 60 fps for a popover preview.
        case previewJPEG = 0x04
        /// User clicked the macOS Control Center's "Stop" button.
        /// Distinct from `fatal` because the main process should
        /// tear the share down rather than respawn the helper —
        /// respawning would immediately reopen the very recording
        /// the user just turned off.
        case userStopped = 0x05
        /// Liveness ping (~1 Hz). Emitted while the SCStream is delivering
        /// samples — including `.idle` frames for a static screen — so the
        /// parent can distinguish a wedged capture (SCStream silently stopped
        /// while the helper process is still alive, which process-death
        /// detection never catches) from a screen that simply isn't changing.
        /// Payload empty.
        case heartbeat = 0x06
        /// Encoded system/computer-audio access unit (AAC-LC mono 48 kHz).
        /// Payload is the raw AAC AU bytes — no keyframe flag, unlike video.
        /// The parent packetizes these as RTP PT 99 and fans them out on the
        /// UDP audio path. Emitted only while the sharer has system audio on
        /// (gated in the helper by the `setAudioEnabled` latch).
        case audioAccessUnit = 0x07
        /// UTF-8 log line from the helper, surfaced into the main
        /// process's merged log so investigation doesn't need to
        /// open the helper's separate stderr.
        case logLine = 0x10
        /// Helper hit a fatal error and is exiting. Payload UTF-8
        /// description.
        case fatal = 0xFF
    }

    /// Main → helper message types.
    enum InType: UInt8 {
        /// Force the next encoded frame to be a keyframe (PLI).
        case requestKeyframe = 0x01
        /// `[4 bytes bitrate BE]` — adaptive-bitrate sweep nudge.
        case setBitrate = 0x02
        /// JSON-encoded `PickerSelection`. Sent once at startup; the
        /// helper waits on stdin for this message before bringing
        /// the SCStream up. Carries primitive IDs (display / window
        /// / bundle) rather than an archived `SCContentFilter`
        /// because `SCContentFilter` doesn't conform to NSCoding.
        /// The helper resolves the IDs to live SC* objects via
        /// `SCShareableContent` and rebuilds the filter on its side.
        case contentFilter = 0x03
        /// `[1 byte: 0=off 1=on]` — enable/disable system-audio *emission*.
        /// The audio SCStream output is configured at start time (see
        /// `PickerSelection.captureAudio`); this latch just gates whether the
        /// helper forwards the encoded AUs, so mute/unmute is instant and
        /// avoids `updateConfiguration` churn on the audio path.
        case setAudioEnabled = 0x04
        /// `[4 bytes fps BE]` — fps-ladder downshift/upshift (60 / 30 / 15).
        /// The helper reconfigures the SCStream's `minimumFrameInterval` (the
        /// second congestion lever, applied once bitrate bottoms out). Runs in
        /// the capture helper, never the main process, per CLAUDE.md.
        case setFrameInterval = 0x05
        /// Helper drains its current frame, calls SCStream.stopCapture,
        /// exits. Payload empty.
        case shutdown = 0xFF
    }

    /// Wire-format access unit. The encoded H.264/HEVC AVCC bytes
    /// the encoder produced.
    struct AccessUnit: Sendable {
        let containsKeyframe: Bool
        let avcc: Data
    }
}

/// Streamed-frame writer. Helper-side; uses blocking `FileHandle.write`
/// onto stdout. Synchronous on purpose — encoder thread blocks if main
/// can't keep up, providing natural backpressure.
final class HelperFrameWriter: @unchecked Sendable {
    private let handle: FileHandle
    /// Serializes `write` so messages produced on different threads — encoded
    /// AUs/params on the encoder's output thread, previews on the MainActor,
    /// heartbeats on the SCStream delegate's queue, and system-audio AUs on
    /// the SCStream audio-output queue — can't interleave their header and
    /// payload writes and desync the framed protocol. Four writer threads now.
    private let writeLock = NSLock()
    init(handle: FileHandle) { self.handle = handle }

    /// Liveness ping; see `OutType.heartbeat`.
    func writeHeartbeat() { write(type: .heartbeat, payload: Data()) }

    /// Encoded system-audio AU; see `OutType.audioAccessUnit`. Payload is the
    /// raw AAC AU bytes — no keyframe flag.
    func writeAudioAccessUnit(_ au: Data) { write(type: .audioAccessUnit, payload: au) }

    func writeAccessUnit(_ data: Data, containsKeyframe: Bool) {
        // Prepend a 1-byte keyframe flag so main can prioritize
        // without re-parsing AVCC.
        var payload = Data(capacity: data.count + 1)
        payload.append(containsKeyframe ? 1 : 0)
        payload.append(data)
        write(type: .accessUnit, payload: payload)
    }

    func writeParameterSets(codec: UInt8, width: Int, height: Int, paramSets: [Data]) {
        var payload = Data()
        payload.append(codec)
        payload.appendBE(UInt32(width))
        payload.appendBE(UInt32(height))
        payload.appendBE(UInt32(paramSets.count))
        for ps in paramSets {
            payload.appendBE(UInt32(ps.count))
            payload.append(ps)
        }
        write(type: .parameterSets, payload: payload)
    }

    func writeFirstFrame() { write(type: .firstFrame, payload: Data()) }

    func writePreviewJPEG(_ jpeg: Data) { write(type: .previewJPEG, payload: jpeg) }

    func writeUserStopped() { write(type: .userStopped, payload: Data()) }

    func writeLog(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        write(type: .logLine, payload: data)
    }

    func writeFatal(_ message: String) {
        let data = message.data(using: .utf8) ?? Data()
        write(type: .fatal, payload: data)
    }

    private func write(type: CaptureHelperWire.OutType, payload: Data) {
        var header = Data()
        header.append(type.rawValue)
        header.appendBE(UInt32(payload.count))
        writeLock.lock()
        defer { writeLock.unlock() }
        try? handle.write(contentsOf: header)
        if !payload.isEmpty {
            try? handle.write(contentsOf: payload)
        }
    }
}

/// Streamed-frame reader. Main-side; reads from helper's stdout pipe
/// asynchronously.
struct HelperFrameReader {
    let handle: FileHandle

    /// Pull one framed message off the pipe. Returns nil on EOF (helper
    /// exited).
    func readNext() -> (type: UInt8, payload: Data)? {
        guard let header = readExactly(5) else { return nil }
        let type = header[0]
        let len = UInt32(header[1]) << 24 | UInt32(header[2]) << 16 | UInt32(header[3]) << 8 | UInt32(header[4])
        let payload: Data
        if len > 0 {
            guard let data = readExactly(Int(len)) else { return nil }
            payload = data
        } else {
            payload = Data()
        }
        return (type, payload)
    }

    private func readExactly(_ count: Int) -> Data? {
        var collected = Data()
        while collected.count < count {
            let need = count - collected.count
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: need) else { return nil }
                chunk = read
            } catch {
                return nil
            }
            if chunk.isEmpty { return nil }
            collected.append(chunk)
        }
        return collected
    }
}

/// Helper-side stdin reader for control messages. Blocking — runs on
/// a dedicated thread.
struct HelperControlReader {
    let handle: FileHandle

    func readNext() -> (type: UInt8, payload: Data)? {
        guard let header = readExactly(5) else { return nil }
        let type = header[0]
        let len = UInt32(header[1]) << 24 | UInt32(header[2]) << 16 | UInt32(header[3]) << 8 | UInt32(header[4])
        let payload = len > 0 ? (readExactly(Int(len)) ?? Data()) : Data()
        return (type, payload)
    }

    private func readExactly(_ count: Int) -> Data? {
        var collected = Data()
        while collected.count < count {
            let need = count - collected.count
            guard let chunk = try? handle.read(upToCount: need), !chunk.isEmpty else { return nil }
            collected.append(chunk)
        }
        return collected
    }
}

/// Main → helper sender. Synchronous writes onto the helper's stdin.
final class HelperControlWriter {
    private let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }

    func sendKeyframeRequest() { write(type: .requestKeyframe, payload: Data()) }

    func sendBitrate(_ bitrate: Int) {
        var payload = Data()
        payload.appendBE(UInt32(max(0, bitrate)))
        write(type: .setBitrate, payload: payload)
    }

    func sendContentFilter(_ data: Data) {
        write(type: .contentFilter, payload: data)
    }

    /// Toggle system-audio emission in the helper; see `InType.setAudioEnabled`.
    func sendAudioEnabled(_ on: Bool) {
        write(type: .setAudioEnabled, payload: Data([on ? 1 : 0]))
    }

    func sendFrameInterval(_ fps: Int) {
        var payload = Data()
        payload.appendBE(UInt32(max(1, fps)))
        write(type: .setFrameInterval, payload: payload)
    }

    func sendShutdown() { write(type: .shutdown, payload: Data()) }

    private func write(type: CaptureHelperWire.InType, payload: Data) {
        var header = Data()
        header.append(type.rawValue)
        header.appendBE(UInt32(payload.count))
        try? handle.write(contentsOf: header)
        if !payload.isEmpty {
            try? handle.write(contentsOf: payload)
        }
    }
}

extension Data {
    fileprivate mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
