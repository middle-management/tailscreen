import Foundation
import TailscaleKit

/// Watches the Tailscale IPN bus for real-time peer status updates
@MainActor
class TailscaleIPNWatcher: ObservableObject {
    @Published var peers: [String: TailscalePeerStatus] = [:]
    @Published var isWatching = false

    private var messageProcessor: MessageProcessor?
    private let logger: TSLogger

    init() {
        self.logger = TSLogger()
    }

    /// Start watching the IPN bus for peer status changes
    func startWatching(node: TailscaleNode) async throws {
        guard !isWatching else { return }

        isWatching = true

        let client = LocalAPIClient(localNode: node, logger: logger)

        // Watch for netmap updates with rate limiting to avoid excessive updates
        let mask: Ipn.NotifyWatchOpt = [.initialState, .netmap, .rateLimitNetmaps]

        let consumer = IPNMessageConsumer(watcher: self)
        messageProcessor = try await client.watchIPNBus(mask: mask, consumer: consumer)

        logger.log("IPN bus watcher started")
    }

    /// Stop watching the IPN bus
    func stopWatching() {
        messageProcessor?.stop()
        messageProcessor = nil
        isWatching = false
        logger.log("IPN bus watcher stopped")
    }

    /// Handle incoming IPN notifications
    nonisolated func handleNotify(_ notify: Ipn.Notify) {
        Task { @MainActor in
            // Process netmap updates to track peer status
            if let netmap = notify.NetMap, let peerMap = netmap.Peers {
                var updatedPeers: [String: TailscalePeerStatus] = [:]

                for (nodeID, peer) in peerMap {
                    let status = TailscalePeerStatus(
                        nodeID: nodeID,
                        hostname: peer.HostName,
                        dnsName: peer.DNSName,
                        tailscaleIPs: peer.TailscaleIPs ?? [],
                        online: peer.Online,
                        lastSeen: peer.LastSeen
                    )
                    updatedPeers[nodeID] = status
                }

                self.peers = updatedPeers
                logger.log("Peer status updated: \(updatedPeers.count) peers")
            }
        }
    }

    /// Handle errors from the IPN bus
    nonisolated func handleError(_ error: Error) {
        Task { @MainActor in
            logger.log("IPN bus error: \(error.localizedDescription)")
        }
    }
}

/// Consumer actor for IPN messages
actor IPNMessageConsumer: MessageConsumer {
    weak var watcher: TailscaleIPNWatcher?

    init(watcher: TailscaleIPNWatcher) {
        self.watcher = watcher
    }

    func notify(_ notify: Ipn.Notify) {
        watcher?.handleNotify(notify)
    }

    func error(_ error: Error) {
        watcher?.handleError(error)
    }
}

/// Represents the status of a Tailscale peer
struct TailscalePeerStatus: Identifiable, Sendable {
    let id: String
    let nodeID: String
    let hostname: String
    let dnsName: String
    let tailscaleIPs: [String]
    let online: Bool
    let lastSeen: String?

    init(nodeID: String, hostname: String, dnsName: String, tailscaleIPs: [String], online: Bool, lastSeen: String?) {
        self.id = nodeID
        self.nodeID = nodeID
        self.hostname = hostname
        self.dnsName = dnsName
        self.tailscaleIPs = tailscaleIPs
        self.online = online
        self.lastSeen = lastSeen
    }
}
