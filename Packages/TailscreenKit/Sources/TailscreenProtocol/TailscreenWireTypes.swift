import Foundation

// JSON wire types for the TCP metadata channel, in their own file (not
// TailscreenMetadata.swift, which is AppKit-bound) because they are part of
// the platform-portable TailscreenProtocol set — see
// Packages/TailscreenKit/README.md. Nothing here may import an Apple
// framework.

/// Metadata about a Tailscreen screen share
public struct TailscreenMetadata: Codable, Sendable, Equatable {
    public var version: String = "1.0"
    public let shareName: String
    public let hostname: String
    public let screenResolution: ScreenResolution
    public let isSharing: Bool
    public let timestamp: Date
    /// Codec the sharer is currently encoding with. Optional for backward
    /// compat with older peers that omit the field — when missing, assume
    /// H.264 (the only codec older Tailscreen builds spoke). The viewer
    /// also auto-detects from the RTP payload type, so this is mainly
    /// informational for the UI.
    public var videoCodec: VideoCodec?

    public struct ScreenResolution: Codable, Sendable, Equatable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public init(
        shareName: String, hostname: String, screenResolution: ScreenResolution,
        isSharing: Bool, timestamp: Date, videoCodec: VideoCodec? = nil
    ) {
        self.shareName = shareName
        self.hostname = hostname
        self.screenResolution = screenResolution
        self.isSharing = isSharing
        self.timestamp = timestamp
        self.videoCodec = videoCodec
    }
}

/// Request types for peer-to-peer communication
public enum TailscreenRequest: Codable, Sendable {
    case requestToShare(from: String)
    case acceptShare
    case declineShare

    public enum CodingKeys: String, CodingKey {
        case type, from
    }

    public enum RequestType: String, Codable {
        case requestToShare
        case acceptShare
        case declineShare
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(RequestType.self, forKey: .type)

        switch type {
        case .requestToShare:
            let from = try container.decode(String.self, forKey: .from)
            self = .requestToShare(from: from)
        case .acceptShare:
            self = .acceptShare
        case .declineShare:
            self = .declineShare
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .requestToShare(let from):
            try container.encode(RequestType.requestToShare, forKey: .type)
            try container.encode(from, forKey: .from)
        case .acceptShare:
            try container.encode(RequestType.acceptShare, forKey: .type)
        case .declineShare:
            try container.encode(RequestType.declineShare, forKey: .type)
        }
    }
}
