import Foundation
import TailscaleKit
import TailscreenProtocol

/// Watches the Tailscale IPN bus for real-time peer status updates
@MainActor
public class TailscaleIPNWatcher: ObservableObject {
    @Published public var peers: [String: TailscalePeerStatus] = [:]
    @Published public var isWatching = false

    /// Fires whenever tsnet asks the host app to send the user to a URL —
    /// most commonly the interactive-login page during the first sign-in.
    /// `node.up()` blocks until login completes, so without surfacing this
    /// URL the app would hang forever on first launch with no auth state.
    public var onBrowseToURL: ((URL) -> Void)?

    private var messageProcessor: MessageProcessor?
    private let logger: PrintLogSink

    public init() {
        self.logger = PrintLogSink(prefix: "IPNWatcher")
    }

    /// Start watching the IPN bus for peer status changes
    public func startWatching(node: TailscaleNode) async throws {
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
    public func stopWatching() {
        messageProcessor?.cancel()
        messageProcessor = nil
        isWatching = false
        logger.log("IPN bus watcher stopped")
    }

    /// Handle incoming IPN notifications
    public nonisolated func handleNotify(_ notify: Ipn.Notify) {
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
                    // `peer.Addresses` is `[IP.Prefix]` (e.g. "100.64.0.1/32").
                    // Strip the CIDR suffix so callers that pass the value
                    // to `tailscale_dial` as `"\(host):\(port)"` end up with
                    // a parseable host — the suffix bleeds through as
                    // "100.64.0.1/32:7447" otherwise, which tsnet rejects.
                    let ipStrings = (peer.Addresses ?? []).map { prefix -> String in
                        if let slash = prefix.firstIndex(of: "/") {
                            return String(prefix[..<slash])
                        }
                        return prefix
                    }
                    let status = TailscalePeerStatus(
                        nodeID: nodeID,
                        hostname: peer.ComputedName,
                        dnsName: peer.Name,
                        tailscaleIPs: ipStrings,
                        online: peer.Online ?? false,
                        lastSeen: peer.LastSeen.map { String($0) },
                        tags: peer.Tags ?? []
                    )
                    updatedPeers[nodeID] = status
                }

                self.peers = updatedPeers
                logger.log("Peer status updated: \(updatedPeers.count) peers")
            }
        }
    }

    /// Handle errors from the IPN bus
    public nonisolated func handleError(_ error: Error) {
        Task { @MainActor in
            logger.log("IPN bus error: \(error.localizedDescription)")
        }
    }
}

/// Consumer actor for IPN messages
public actor IPNMessageConsumer: MessageConsumer {
    public weak var watcher: TailscaleIPNWatcher?

    public init(watcher: TailscaleIPNWatcher) {
        self.watcher = watcher
    }

    public func notify(_ notify: Ipn.Notify) {
        watcher?.handleNotify(notify)
    }

    public func error(_ error: Error) {
        watcher?.handleError(error)
    }
}

/// Represents the status of a Tailscale peer
public struct TailscalePeerStatus: Identifiable, Sendable {
    public let id: String
    public let nodeID: String
    public let hostname: String
    public let dnsName: String
    public let tailscaleIPs: [String]
    public let online: Bool
    public let lastSeen: String?
    /// Tailscale ACL tags ("tag:server") from the netmap node. Empty for
    /// untagged (typically interactive-login personal) nodes.
    public let tags: [String]

    public init(
        nodeID: String, hostname: String, dnsName: String, tailscaleIPs: [String], online: Bool,
        lastSeen: String?, tags: [String] = []
    ) {
        self.id = nodeID
        self.nodeID = nodeID
        self.hostname = hostname
        self.dnsName = dnsName
        self.tailscaleIPs = tailscaleIPs
        self.online = online
        self.lastSeen = lastSeen
        self.tags = tags
    }
}
