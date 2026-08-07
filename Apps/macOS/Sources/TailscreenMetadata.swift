import AppKit
import Foundation
import TailscaleKit

// TailscreenMetadata / TailscreenRequest live in TailscreenWireTypes.swift
// (platform-portable, part of TailscreenProtocol).

/// Service for managing Tailscreen metadata and requests.
///
/// The incoming request-to-share inbox is NOT here anymore: the coalescing,
/// cap and expiry are `ShareRequestInbox` (TailscreenProtocol) and the
/// listener + answer sequencing are `SharerAskToShareCoordinator`
/// (TailscreenSharer) — shared with the GTK and Windows apps, and adopted by
/// `AppState`. What remains is the metadata half of the conversation.
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

    /// The metadata served to a peer's `.metadataRequest` (the sharing-
    /// status filter's fetch half). Falls back to an idle, not-sharing
    /// snapshot when no share has run this session (`currentMetadata` is
    /// nil until the first `updateMetadata` call) — answering is what lets
    /// a requester distinguish "reachable but not sharing" from "no
    /// answer" (offline / legacy build).
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

    /// Send a request-to-share prompt to `toIP` over the framed control
    /// protocol on the peer's tsnet listener, then hold the connection open
    /// waiting for the peer's `.shareResponse` frame so the requester learns
    /// whether they were accepted or declined. Timeout / EOF map to
    /// `.noAnswer` — which is also exactly what an old peer that doesn't
    /// speak `shareResponse` produces. The receive side picks the request up
    /// through `TailscreenControlListener.onRequestToShare` and answers on
    /// this same connection.
    ///
    /// Both the `OutgoingConnection` init and `connect()` are wrapped in
    /// `TailscalePeerDiscovery.withWatchdog` because `tailscale_dial` (and
    /// the init's actor handshake) can block indefinitely on ACL-dropped
    /// SYNs or a cold netmap — without the watchdog the UI Task hangs
    /// forever and the error never surfaces. The response wait itself needs
    /// no watchdog: it polls `receive` with a bounded per-call timeout.
    @discardableResult
    func sendRequestToShareAwaitingResponse(
        toIP host: String,
        port: UInt16 = NetworkConfig.tailscreenPort,
        from hostname: String,
        via node: TailscaleNode,
        responseTimeout: TimeInterval = 120
    ) async throws -> ShareRequestOutcome {
        // Forwards to the portable client, which is this method's own body
        // moved into `TailscreenTransport` so the Linux and Windows apps could
        // ask too. Kept as a method rather than deleted because every call
        // site here reads better against the service that serves the metadata
        // half of the same conversation.
        //
        // One behaviour improved in the move: an EOF now settles the wait
        // immediately instead of polling on to the full timeout. A peer that
        // closes without answering used to cost the requester two minutes of
        // "asking…" for an answer that was never coming.
        try await TailscreenRequestToShareClient.requestToShare(
            toIP: host, port: port, from: hostname, via: node,
            responseTimeout: responseTimeout)
    }
}

// `ShareRequestOutcome` now lives in `TailscreenTransport` beside the client
// that produces it, and reaches this file through `ProtocolReexports`. The
// local copy was deleted rather than renamed: two identical enums, one of them
// shadowing the other through an `@_exported import`, is the ambiguity
// CLAUDE.md warns about for `ProfileStore` — and here there was no reason for
// a second one to exist.
