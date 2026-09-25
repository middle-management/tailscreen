import Foundation
import PortalCaptureKit

/// Owns this app's `PortalSession` and is the only thing that ever touches it.
///
/// **Every call goes through one serial queue.** libdbus expects a
/// `PortalSession`'s D-Bus connection driven from a single thread, but this
/// app touches it from three (startup probe, consent negotiation off the GTK
/// main thread, and the capture factory's PipeWire open) — funnelling them
/// through one queue is what makes that safe.
///
/// Holds the session **for the life of the share**: negotiating raises a
/// consent dialog, so a restart that renegotiated would put one in front of
/// someone already sharing. The restart budget only reopens the PipeWire
/// stream.
final class PortalSessionHost: @unchecked Sendable {
    /// What happened when we asked the user to share.
    enum Outcome {
        case granted(nodeID: UInt32)
        /// Declined or dismissed — not an error, a normal end to the flow.
        case cancelled
        case failed(String)
    }

    /// Dedicated: `negotiate` blocks this thread for as long as the consent
    /// dialog is up, so it can't be shared with anything needing to progress
    /// meanwhile.
    private let queue = DispatchQueue(label: "tailscreen.portal-session")
    private var session: PortalSession?

    /// Whether a portal answered — puts **nothing** on screen.
    /// `CaptureBackendSelection` needs this to choose a backend without
    /// raising a consent dialog just to decide whether to ask for consent.
    func probeAvailability() -> Bool {
        queue.sync {
            guard let probe = try? PortalSession() else { return false }
            do {
                try probe.connect()
                return true
            } catch {
                return false
            }
        }
    }

    /// Raise the consent dialog and, if the user agrees, keep the session.
    /// Async: blocks until they answer or time out, called from the GTK main
    /// thread.
    func negotiate(sources: PortalSession.SourceTypes) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: negotiateOnQueue(sources: sources))
            }
        }
    }

    private func negotiateOnQueue(sources: PortalSession.SourceTypes) -> Outcome {
        let opened: PortalSession
        do {
            opened = try PortalSession()
            try opened.connect()
        } catch {
            return .failed("\(error)")
        }
        do {
            let streams = try opened.negotiate(sources: sources, cursor: .embedded)
            guard let first = streams.first else {
                return .failed("the portal granted the share but returned nothing to capture")
            }
            // Held only on success, so a declined/failed attempt leaves no
            // stale handle for the next try to reuse.
            session = opened
            return .granted(nodeID: first.nodeID)
        } catch PortalSession.Failure.cancelled {
            return .cancelled
        } catch {
            return .failed("\(error)")
        }
    }

    /// Opens a PipeWire descriptor on the negotiated session; called by
    /// `PortalCaptureEncoder` at every start, including after a restart.
    /// Synchronous: the caller isn't async, and this is a local D-Bus round
    /// trip, not a dialog.
    func openPipeWireFileDescriptor() throws -> Int32 {
        try queue.sync {
            guard let session else {
                throw PortalSession.Failure.portalError("no negotiated portal session")
            }
            return try session.openPipeWireFileDescriptor()
        }
    }

    /// Ends the session, dropping the compositor's sharing indicator.
    /// Idempotent.
    func close() {
        queue.sync {
            session?.close()
            session = nil
        }
    }
}
