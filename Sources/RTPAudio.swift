import Foundation

/// Packs AAC-LC access units into RTP packets, one AU per packet, with a
/// 48 kHz audio clock and a stable per-channel SSRC. The RTP timestamp
/// advances by 1024 (the AU's frame count) per packet — this matches the
/// AAC frame rate at 48 kHz.
final class AudioRTPPacketizer {
    let ssrc: UInt32
    private var sequence: UInt16
    private var timestamp: UInt32

    init(ssrc: UInt32, startSequence: UInt16 = 0, startTimestamp: UInt32 = 0) {
        self.ssrc = ssrc
        self.sequence = startSequence
        self.timestamp = startTimestamp
    }

    func packetize(au: Data) -> Data {
        var packet = Data(capacity: RTPHeader.size + au.count)
        let header = RTPHeader(
            marker: true,
            payloadType: RTPHeader.aacPayloadType,
            sequenceNumber: sequence,
            timestamp: timestamp,
            ssrc: ssrc
        )
        header.encode(into: &packet)
        packet.append(au)
        sequence &+= 1
        timestamp &+= 1024
        return packet
    }
}

/// Stateless RTP audio unpacker. Stateless because mixing across multiple
/// SSRCs happens in the caller — VoiceChannel keeps a decoder per SSRC.
struct AudioRTPDepacketizer {
    struct Parsed {
        let ssrc: UInt32
        let timestamp: UInt32
        let sequenceNumber: UInt16
        let payloadType: UInt8
        let au: Data
    }

    func unpack(_ packet: Data) -> Parsed? {
        guard let (header, payloadOffset) = RTPHeader.decode(from: packet) else { return nil }
        guard header.payloadType == RTPHeader.aacPayloadType else { return nil }
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
