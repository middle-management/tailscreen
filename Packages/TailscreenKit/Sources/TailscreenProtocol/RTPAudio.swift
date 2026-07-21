import Foundation

/// Packs audio access units (Opus packets) into RTP packets, one AU per
/// packet, with a 48 kHz audio clock and a stable per-channel SSRC. The RTP
/// timestamp advances by `samplesPerFrame` (960 — one Opus 20 ms frame at
/// 48 kHz) per packet.
///
/// Not thread-safe: the mutable sequence + timestamp counters require the
/// caller to serialize `packetize(au:)` calls. `VoiceChannel` confines
/// every call to its internal serial queue.
public final class AudioRTPPacketizer {
    /// RTP timestamp step per packet: samples in one Opus 20 ms frame at
    /// 48 kHz. Kept here (not imported from OpusKit) so this stays a
    /// Foundation-only, Linux-buildable protocol file; it must equal
    /// `OpusVoiceEncoder.frameSamples`.
    public static let samplesPerFrame: UInt32 = 960

    public let ssrc: UInt32
    /// RTP payload type stamped on every packet. Defaults to
    /// `voicePayloadType` (98) so voice call sites are untouched; the server's
    /// system-audio path passes `systemAudioPayloadType` (99).
    public let payloadType: UInt8
    private var sequence: UInt16
    private var timestamp: UInt32

    public init(
        ssrc: UInt32,
        payloadType: UInt8 = RTPHeader.voicePayloadType,
        startSequence: UInt16 = 0,
        startTimestamp: UInt32 = 0
    ) {
        self.ssrc = ssrc
        self.payloadType = payloadType
        self.sequence = startSequence
        self.timestamp = startTimestamp
    }

    public func packetize(au: Data) -> Data {
        var packet = Data(capacity: RTPHeader.size + au.count)
        let header = RTPHeader(
            marker: true,
            payloadType: payloadType,
            sequenceNumber: sequence,
            timestamp: timestamp,
            ssrc: ssrc
        )
        header.encode(into: &packet)
        packet.append(au)
        sequence &+= 1
        timestamp &+= Self.samplesPerFrame
        return packet
    }
}

/// Stateless RTP audio unpacker. Stateless because mixing across multiple
/// SSRCs happens in the caller — VoiceChannel keeps a decoder per SSRC.
public struct AudioRTPDepacketizer {
    public init() {}

    public struct Parsed {
        public let ssrc: UInt32
        public let timestamp: UInt32
        public let sequenceNumber: UInt16
        public let payloadType: UInt8
        public let au: Data
    }

    public func unpack(_ packet: Data) -> Parsed? {
        guard let (header, payloadOffset) = RTPHeader.decode(from: packet) else { return nil }
        let pt = header.payloadType
        let isAudioPT = pt == RTPHeader.voicePayloadType || pt == RTPHeader.systemAudioPayloadType
        guard isAudioPT else { return nil }
        let payload = packet[packet.index(packet.startIndex, offsetBy: payloadOffset)..<packet.endIndex]
        guard !payload.isEmpty else { return nil }
        return Parsed(
            ssrc: header.ssrc,
            timestamp: header.timestamp,
            sequenceNumber: header.sequenceNumber,
            payloadType: header.payloadType,
            au: Data(payload)
        )
    }
}
