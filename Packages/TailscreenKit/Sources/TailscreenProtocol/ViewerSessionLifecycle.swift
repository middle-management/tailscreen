import Foundation

/// Where a viewer session's presentation is in its lifecycle.
///
/// Dependency-free protocol tier, not a UI package or transport: macOS, GTK
/// and WinUI all render the same five states from one enum instead of three
/// that could drift.
public enum ViewerSessionPhase: Equatable, Sendable {
    case connecting
    case awaitingApproval
    case viewing
    case ended(ViewerSessionEndReason)
    case failed(String)

    /// The terminal states that stay on screen until Reconnect or Back.
    public var isOver: Bool {
        switch self {
        case .ended, .failed: true
        default: false
        }
    }
}

/// Opaque identity for one invocation of `ViewerSessionLifecycle.begin`.
///
/// Asynchronous callbacks carry this value back into transition methods so a
/// callback queued by an old session cannot advance whichever session happens
/// to be current when it finally runs.
public struct ViewerSessionID: Equatable, Hashable, Sendable {
    fileprivate let value: UInt64
}

/// Everything a host needs to redial the current or most recent viewer.
///
/// `identifier` is the hub row id when reconnect resolves through a fresh
/// peer list (WinUI); `host` is the address to dial directly (macOS, GTK). A
/// guest has neither — its opaque token is the route. One value replaces the
/// parallel `lastPeer`/`lastGuestToken` slots every host had to sync.
public struct ViewerSessionTarget: Equatable, Sendable {
    public let identifier: String?
    public let host: String
    public let displayName: String
    public let guestToken: String?

    public init(
        identifier: String? = nil,
        host: String,
        displayName: String,
        guestToken: String? = nil
    ) {
        self.identifier = identifier
        self.host = host
        self.displayName = displayName
        self.guestToken = guestToken
    }

    public var isGuest: Bool { guestToken != nil }
}

/// Portable, deterministic viewer-session presentation state.
///
/// The model owns decisions, not effects: a host still creates its decoder,
/// runs `TsnetTransport`, shows windows and performs the eventual redial. The
/// shared part is which transition is legal, what remains visible after an
/// end, and which target survives for Reconnect.
public struct ViewerSessionLifecycle: Equatable, Sendable {
    public private(set) var phase: ViewerSessionPhase?
    public private(set) var target: ViewerSessionTarget?
    public private(set) var sessionID: ViewerSessionID?
    private var nextSessionValue: UInt64 = 0

    public init() {}

    /// Begin owning the viewer presentation for `target`.
    @discardableResult
    public mutating func begin(_ target: ViewerSessionTarget) -> ViewerSessionID {
        nextSessionValue &+= 1
        let id = ViewerSessionID(value: nextSessionValue)
        self.target = target
        sessionID = id
        phase = .connecting
        return id
    }

    /// Whether `id` still names the current session, including its retained
    /// terminal presentation.
    public func isCurrent(_ id: ViewerSessionID) -> Bool {
        sessionID == id && phase != nil
    }

    /// Whether callbacks from `id` may still apply non-terminal side effects.
    public func isActive(_ id: ViewerSessionID) -> Bool {
        isCurrent(id) && phase?.isOver == false
    }

    /// Apply HELLO_PENDING. Returns false for a callback from a session that
    /// has been replaced, ended or dismissed.
    @discardableResult
    public mutating func markAwaitingApproval(for id: ViewerSessionID) -> Bool {
        guard isCurrent(id), phase == .connecting else { return false }
        phase = .awaitingApproval
        return true
    }

    /// Apply HELLO_ACK / first decoded frame. Both connecting and pending are
    /// valid predecessors; terminal or dismissed sessions reject stale hops.
    @discardableResult
    public mutating func markViewing(for id: ViewerSessionID) -> Bool {
        guard isCurrent(id), phase == .connecting || phase == .awaitingApproval else {
            return false
        }
        phase = .viewing
        return true
    }

    /// Keep the presentation up with the portable end reason.
    @discardableResult
    public mutating func end(_ reason: ViewerSessionEndReason, for id: ViewerSessionID) -> Bool {
        guard isActive(id) else { return false }
        phase = .ended(reason)
        return true
    }

    /// Keep the presentation up with a bring-up/runtime failure.
    @discardableResult
    public mutating func fail(_ message: String, for id: ViewerSessionID) -> Bool {
        guard isActive(id) else { return false }
        phase = .failed(message)
        return true
    }

    /// Reconnect and Back both dismiss the current presentation. The target
    /// deliberately survives: Reconnect reads it immediately, and retaining
    /// it after Back preserves the last-session context macOS uses in
    /// notices and accessibility labels.
    public mutating func dismiss() {
        phase = nil
        sessionID = nil
    }

    /// Session-tail variant of `dismiss()`: an old task cannot dismiss the
    /// replacement that started after it.
    @discardableResult
    public mutating func dismiss(ifCurrent id: ViewerSessionID) -> Bool {
        guard isCurrent(id) else { return false }
        dismiss()
        return true
    }

    /// Sign-out / account teardown is the stronger reset: no session UI and
    /// no target from the account that just went away.
    public mutating func forget() {
        phase = nil
        target = nil
        sessionID = nil
    }
}
