import Foundation
import TailscaleKit

/// Watches the Tailscale IPN bus for real-time peer status updates
@MainActor
class TailscaleIPNWatcher: ObservableObject {
    @Published var peers: [String: TailscalePeerStatus] = [:]
    @Published var isWatching = false

    /// Fires whenever tsnet asks the host app to send the user to a URL —
    /// most commonly the interactive-login page during the first sign-in.
    /// `node.up()` blocks until login completes, so without surfacing this
    /// URL the app would hang forever on first launch with no auth state.
    var onBrowseToURL: ((URL) -> Void)?

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

        // Watch for netmap updates with rate limiting to avoid excessive
        // updates. `.initialState` is what makes tsnet replay the current
        // browse-to-URL on first subscribe, so we catch it even if it was
        // generated before this watcher started.
        let mask: Ipn.NotifyWatchOpt = [.initialState, .netmap, .rateLimitNetmaps]

        let consumer = IPNMessageConsumer(watcher: self)
        messageProcessor = try await client.watchIPNBus(mask: mask, consumer: consumer)

        logger.log("IPN bus watcher started")
    }

    /// Stop watching the IPN bus
    func stopWatching() {
        messageProcessor?.cancel()
        messageProcessor = nil
        isWatching = false
        logger.log("IPN bus watcher stopped")
    }

    /// Handle incoming IPN notifications
    nonisolated func handleNotify(_ notify: Ipn.Notify) {
        Task { @MainActor in
            // tsnet emits BrowseToURL whenever the user needs to visit a
            // page in their browser — primarily the interactive-login URL
            // during first sign-in. Forward to the host app so it can
            // open it via NSWorkspace.
            if let raw = notify.BrowseToURL, let url = URL(string: raw) {
                logger.log("BrowseToURL: \(raw)")
                onBrowseToURL?(url)
            }

            // Process netmap updates to track peer status
            if let netmap = notify.NetMap, let peerMap = netmap.Peers {
                var updatedPeers: [String: TailscalePeerStatus] = [:]

                for peer in peerMap {
                    let nodeID = String(peer.ID)
                    // Convert IP.Prefix addresses to string array
                    let ipStrings = (peer.Addresses ?? []).map { String($0) }
                    let status = TailscalePeerStatus(
                        nodeID: nodeID,
                        hostname: peer.ComputedName,
                        dnsName: peer.Name,
                        tailscaleIPs: ipStrings,
                        online: peer.Online ?? false,
                        lastSeen: peer.LastSeen != nil ? String(peer.LastSeen!) : nil
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

    init(
        nodeID: String, hostname: String, dnsName: String, tailscaleIPs: [String], online: Bool,
        lastSeen: String?
    ) {
        self.id = nodeID
        self.nodeID = nodeID
        self.hostname = hostname
        self.dnsName = dnsName
        self.tailscaleIPs = tailscaleIPs
        self.online = online
        self.lastSeen = lastSeen
    }
}

// MARK: - Logger Implementation

private struct TSLogger: LogSink {
    var logFileHandle: Int32? = nil

    func log(_ message: String) {
        print("[IPNWatcher] \(message)")
    }
}
