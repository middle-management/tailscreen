import AppKit
import Foundation
import TailscaleKit

// TailscreenMetadata / TailscreenRequest live in TailscreenWireTypes.swift
// (platform-portable, part of TailscreenProtocol).

/// The request-to-share inbox lives elsewhere (`ShareRequestInbox`,
/// `SharerAskToShareCoordinator`); this is only the metadata half.
@MainActor
class TailscreenMetadataService: ObservableObject {
    @Published var currentMetadata: TailscreenMetadata?

    /// Get current screen resolution
    private func getCurrentScreenResolution() -> TailscreenMetadata.ScreenResolution {
        guard let screen = NSScreen.main else {
            return TailscreenMetadata.ScreenResolution(width: 1920, height: 1080)
        }

        let frame = screen.frame
        return TailscreenMetadata.ScreenResolution(
            width: Int(frame.width),
            height: Int(frame.height)
        )
    }

    /// Update metadata when sharing starts
    func updateMetadata(isSharing: Bool, shareName: String? = nil) {
        let hostname = Host.current().localizedName ?? "Unknown"
        let name = shareName ?? "\(hostname)'s Screen"

        currentMetadata = TailscreenMetadata(
            shareName: name,
            hostname: hostname,
            screenResolution: getCurrentScreenResolution(),
            isSharing: isSharing,
            timestamp: Date()
        )
    }

    /// Falls back to an idle snapshot when no share has run this session, so
    /// a requester can tell "reachable but not sharing" from "no answer".
    func wireMetadata() -> TailscreenMetadata {
        if let current = currentMetadata { return current }
        return TailscreenMetadata(
            shareName: "",
            hostname: Host.current().localizedName ?? "Unknown",
            screenResolution: getCurrentScreenResolution(),
            isSharing: false,
            timestamp: Date()
        )
    }

    /// Create metadata JSON for API response
    func getMetadataJSON() throws -> Data {
        guard let metadata = currentMetadata else {
            throw NSError(
                domain: "TailscreenMetadata", code: 1, userInfo: [NSLocalizedDescriptionKey: "No metadata available"])
        }
        return try JSONEncoder().encode(metadata)
    }

    /// Timeout/EOF map to `.noAnswer`, same as an old peer that doesn't speak
    /// `shareResponse`. Both `OutgoingConnection` init and `connect()` are
    /// wrapped in `TailscalePeerDiscovery.withWatchdog`, since `tailscale_dial`
    /// can block indefinitely on ACL-dropped SYNs or a cold netmap.
    @discardableResult
    func sendRequestToShareAwaitingResponse(
        toIP host: String,
        port: UInt16 = NetworkConfig.tailscreenPort,
        from hostname: String,
        via node: TailscaleNode,
        responseTimeout: TimeInterval = 120
    ) async throws -> ShareRequestOutcome {
        // Forwards to the portable client, kept as a method here since every
        // call site reads better against the service serving the metadata
        // half of the same conversation.
        try await TailscreenRequestToShareClient.requestToShare(
            toIP: host, port: port, from: hostname, via: node,
            responseTimeout: responseTimeout)
    }
}

// `ShareRequestOutcome` lives in `TailscreenTransport`, reached here through
// `ProtocolReexports`.
