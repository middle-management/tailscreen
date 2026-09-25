import Foundation
import TailscaleKit
import TailscreenProtocol

/// A live watch-ipn-bus subscription, as far as the watcher cares: something
/// it can cancel. `MessageProcessor` is the production one; a test hands the
/// watcher a fake through `startWatching(subscriber:)`. Internal, like the
/// seam: the app only ever sees `startWatching(node:)`.
protocol IPNBusSubscription: AnyObject, Sendable {
    func cancel()
}

extension MessageProcessor: IPNBusSubscription {}

/// Watches the Tailscale IPN bus for real-time peer status updates.
///
/// The subscription is meant to live for the node's lifetime, but the stream
/// under it doesn't always cooperate — a LocalAPI HTTP timeout or loopback
/// hiccup delivers a terminal `error(_:)` with no more messages. A
/// non-cancellation error tears the subscription down and resubscribes with
/// backoff: the node and loopback address are unchanged, so a fresh
/// `watch-ipn-bus` is all it takes.
@MainActor
public class TailscaleIPNWatcher: ObservableObject {
    @Published public var peers: [String: TailscalePeerStatus] = [:]

    /// True while a subscription is live and delivering. Off between a
    /// failure and its reconnect (host can show "reconnecting"), and after
    /// `stopWatching()`. Whether the watcher *wants* to be subscribed is
    /// `armed`.
    @Published public var isWatching = false

    /// Fires whenever tsnet asks the host app to send the user to a URL —
    /// most commonly the interactive-login page during the first sign-in.
    /// `node.up()` blocks until login completes, so without surfacing this
    /// URL the app would hang forever on first launch with no auth state.
    /// Wired once; every reconnect's consumer forwards through it.
    public var onBrowseToURL: ((URL) -> Void)?

    /// Opens one subscription and hands back its handle. Called once per
    /// (re)connect with a fresh consumer; the same closure serves every
    /// attempt, so whatever it captures (the node, the mask) is shared.
    typealias Subscriber =
        @Sendable (IPNMessageConsumer) async throws -> any IPNBusSubscription

    /// Backoff between reconnect attempts, in seconds; the last entry repeats.
    static let defaultReconnectDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    /// A reconnect attempt that parks (LocalAPI briefly unreachable) must not
    /// wedge the loop, so each attempt runs under a watchdog. A late success
    /// past the deadline is still adopted if nothing else has been by then,
    /// else cancelled — see `adopt`.
    static let defaultReconnectWatchdogSeconds: Double = 15

    private var subscription: (any IPNBusSubscription)?
    /// The consumer whose subscription is live. Errors/notifies from any
    /// other consumer are stragglers from a torn-down subscription, ignored —
    /// else a dying stream's terminal error would restart its own replacement.
    private var currentConsumer: IPNMessageConsumer?
    /// The attempts still opening, by consumer. A processor starts inside the
    /// subscriber call, before `adopt` runs, so a notify then is real (the
    /// `.initialState` replay) and an error then is remembered for adoption.
    /// Keyed per attempt, not one slot — the watchdog can leave a timed-out
    /// attempt running beside the next one, and a single slot would forget
    /// the older attempt's failure.
    private struct OpeningAttempt {
        let consumer: IPNMessageConsumer
        var failure: Error?
    }
    private var opening: [ObjectIdentifier: OpeningAttempt] = [:]
    private var subscriber: Subscriber?
    private var armed = false
    /// Bumped by every start and stop, so an attempt that was in flight across
    /// a stop cannot install its result into a later session.
    private var epoch = 0
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private let reconnectDelays: [TimeInterval]
    private let reconnectWatchdogSeconds: Double
    private let logger: PrintLogSink

    public convenience init() {
        self.init(
            reconnectDelays: Self.defaultReconnectDelays,
            reconnectWatchdogSeconds: Self.defaultReconnectWatchdogSeconds)
    }

    /// The tunable form is internal: the reconnect suite shrinks both so a
    /// reconnect lands within a poll, and nothing else has a reason to.
    init(reconnectDelays: [TimeInterval], reconnectWatchdogSeconds: Double) {
        precondition(!reconnectDelays.isEmpty, "reconnectDelays must not be empty")
        self.reconnectDelays = reconnectDelays
        self.reconnectWatchdogSeconds = reconnectWatchdogSeconds
        self.logger = PrintLogSink(prefix: "IPNWatcher")
    }

    /// Start watching the IPN bus for peer status changes
    public func startWatching(node: TailscaleNode) async throws {
        let client = LocalAPIClient(localNode: node, logger: logger)

        // `.initialState` makes tsnet replay the current browse-to-URL on
        // first subscribe (catching one generated before this watcher
        // started), and on reconnect replays the netmap so `peers` is whole
        // again without waiting for the next change.
        let mask: Ipn.NotifyWatchOpt = [.initialState, .netmap, .rateLimitNetmaps]

        try await startWatching { consumer in
            try await client.watchIPNBus(mask: mask, consumer: consumer)
        }
    }

    /// Start watching through an arbitrary subscriber — the seam the
    /// reconnect suite drives; `startWatching(node:)` is this with the
    /// LocalAPI client.
    ///
    /// Idempotent while armed. A subscriber that throws on the first attempt
    /// disarms the watcher again before rethrowing, so the caller sees the
    /// same watcher it would have seen had it never called.
    func startWatching(subscriber: @escaping Subscriber) async throws {
        guard !armed else { return }
        armed = true
        epoch += 1
        reconnectAttempt = 0
        self.subscriber = subscriber

        let startEpoch = epoch
        do {
            try await subscribe(subscriber, epoch: startEpoch)
        } catch {
            if epoch == startEpoch {
                disarm()
            }
            throw error
        }
        logger.log("IPN bus watcher started")
    }

    /// Stop watching the IPN bus
    public func stopWatching() {
        disarm()
        logger.log("IPN bus watcher stopped")
    }

    private func disarm() {
        epoch += 1
        armed = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        subscriber = nil
        opening.removeAll()
        dropSubscription()
    }

    /// Cancel the live subscription, if any, and forget it. Dropping the last
    /// reference matters as much as `cancel()` — `MessageProcessor.cancel()`
    /// only stops the poll task; the HTTP stream closes in `deinit`.
    private func dropSubscription() {
        subscription?.cancel()
        subscription = nil
        currentConsumer = nil
        isWatching = false
    }

    // MARK: - Subscribing

    private func subscribe(_ subscriber: Subscriber, epoch attemptEpoch: Int) async throws {
        let consumer = beginOpening()
        let handle: any IPNBusSubscription
        do {
            handle = try await subscriber(consumer)
        } catch {
            forgetOpening(consumer)
            throw error
        }
        adopt(handle, consumer: consumer, epoch: attemptEpoch)
    }

    private func beginOpening() -> IPNMessageConsumer {
        let consumer = IPNMessageConsumer(watcher: self)
        opening[ObjectIdentifier(consumer)] = OpeningAttempt(consumer: consumer)
        return consumer
    }

    private func isOpening(_ consumer: IPNMessageConsumer) -> Bool {
        opening[ObjectIdentifier(consumer)] != nil
    }

    /// Close out an attempt's opening record and hand back the error its
    /// stream reported while it was still opening, if any.
    @discardableResult
    private func forgetOpening(_ consumer: IPNMessageConsumer) -> Error? {
        opening.removeValue(forKey: ObjectIdentifier(consumer))?.failure
    }

    /// Install a freshly opened subscription — unless stopped/restarted
    /// while opening, or another attempt already won, in which case the
    /// newcomer is cancelled so no stream runs unowned. A stream that died
    /// while opening is adopted and immediately failed, taking the same
    /// reconnect path as one that dies later.
    private func adopt(_ handle: any IPNBusSubscription, consumer: IPNMessageConsumer, epoch attemptEpoch: Int) {
        let failure = forgetOpening(consumer)
        guard armed, attemptEpoch == epoch, subscription == nil else {
            handle.cancel()
            return
        }
        subscription = handle
        currentConsumer = consumer
        reconnectAttempt = 0
        isWatching = true
        if let failure {
            subscriptionFailed(failure, from: consumer)
        }
    }

    // MARK: - Reconnecting

    private func subscriptionFailed(_ error: Error, from consumer: IPNMessageConsumer) {
        if isOpening(consumer) {
            // Died before its subscribe call returned; `adopt` acts on it.
            opening[ObjectIdentifier(consumer)]?.failure = error
            return
        }
        guard armed, consumer === currentConsumer else {
            // A straggler from a subscription already replaced or stopped.
            return
        }
        logger.log("IPN bus error: \(error.localizedDescription) — reconnecting")
        dropSubscription()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard armed else { return }
        let delay = reconnectDelays[min(reconnectAttempt, reconnectDelays.count - 1)]
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let attemptEpoch = epoch
        logger.log("IPN bus reconnect #\(attempt) in \(delay)s")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.reconnect(attempt: attempt, epoch: attemptEpoch)
        }
    }

    private func reconnect(attempt: Int, epoch attemptEpoch: Int) async {
        guard armed, attemptEpoch == epoch, subscription == nil, let subscriber else { return }
        let consumer = beginOpening()
        do {
            try await TailscalePeerDiscovery.withWatchdog(seconds: reconnectWatchdogSeconds) {
                let handle: any IPNBusSubscription
                do {
                    handle = try await subscriber(consumer)
                } catch {
                    await self.forgetOpening(consumer)
                    throw error
                }
                await self.adopt(handle, consumer: consumer, epoch: attemptEpoch)
            }
            // The watchdog can hand back before `adopt` ran (it timed out and
            // the attempt is still parked) — `isWatching` is the truth.
            if isWatching {
                logger.log("IPN bus watcher reconnected (attempt #\(attempt))")
                return
            }
        } catch {
            logger.log("IPN bus reconnect #\(attempt) failed: \(error.localizedDescription)")
        }
        if armed, attemptEpoch == epoch, subscription == nil {
            scheduleReconnect()
        }
    }

    // MARK: - Consumer callbacks

    /// Handle incoming IPN notifications
    nonisolated func handleNotify(_ notify: Ipn.Notify, from consumer: IPNMessageConsumer) {
        Task { @MainActor in
            guard consumer === currentConsumer || isOpening(consumer) else { return }

            // tsnet emits BrowseToURL for the interactive-login URL during
            // first sign-in; forward to the host app to open.
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

    /// Handle errors from the IPN bus. `MessageReader` already swallows the
    /// cancellation its own `stop()` produces, so everything that reaches
    /// here is a stream that died on us.
    nonisolated func handleError(_ error: Error, from consumer: IPNMessageConsumer) {
        Task { @MainActor in
            subscriptionFailed(error, from: consumer)
        }
    }
}

/// Consumer actor for IPN messages. One per subscription: the watcher tells
/// a live subscription from a torn-down one by which consumer is talking.
public actor IPNMessageConsumer: MessageConsumer {
    public weak var watcher: TailscaleIPNWatcher?

    public init(watcher: TailscaleIPNWatcher) {
        self.watcher = watcher
    }

    public func notify(_ notify: Ipn.Notify) {
        watcher?.handleNotify(notify, from: self)
    }

    public func error(_ error: Error) {
        watcher?.handleError(error, from: self)
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
