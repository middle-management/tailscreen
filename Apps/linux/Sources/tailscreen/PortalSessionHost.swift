import Foundation
import PortalCaptureKit

/// Owns this app's `PortalSession` and is the only thing that ever touches it.
///
/// **Every call goes through one serial queue, and that is not tidiness.** A
/// `PortalSession` holds a private D-Bus connection libdbus expects to be
/// driven from a single thread, and the three things this app does with it
/// happen on three different ones: availability is probed at startup, consent
/// is negotiated off the GTK main thread (the dialog can sit on screen for
/// minutes and blocking the UI thread for that would freeze the app), and the
/// PipeWire descriptor is opened by the screen-share server's capture factory
/// on whichever thread it happens to be running. Funnelling them is what makes
/// that safe.
///
/// It also holds the session **for the life of the share**, which is the point:
/// negotiating raises a consent dialog, so a restart that renegotiated would
/// put one in front of somebody who is already sharing. The server's restart
/// budget only reopens the PipeWire stream.
final class PortalSessionHost: @unchecked Sendable {
    /// What happened when we asked the user to share.
    enum Outcome {
        case granted(nodeID: UInt32)
        /// The person declined, or dismissed the dialog. **Not an error.**
        /// A share that did not happen because somebody said no is a normal
        /// end to the flow, and reporting it as a failure would put an error
        /// in front of a person who made a deliberate choice.
        case cancelled
        case failed(String)
    }

    /// Serial, and dedicated: `negotiate` blocks its thread for as long as the
    /// consent dialog is up, so this queue must not be shared with anything
    /// that needs to make progress meanwhile.
    private let queue = DispatchQueue(label: "tailscreen.portal-session")
    private var session: PortalSession?

    /// Whether a portal answered — a capability check that puts **nothing** on
    /// anyone's screen.
    ///
    /// This distinction is load-bearing: `CaptureBackendSelection` needs to
    /// know whether the portal exists in order to choose a backend, and a
    /// check that raised a dialog would mean asking the user for consent
    /// before deciding whether to ask the user for consent.
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
    ///
    /// Async because the dialog is a person: `negotiate` blocks until they
    /// answer or the timeout elapses, and the caller is the GTK main thread.
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
            // Held only on success. A declined or failed negotiation leaves
            // no session behind, so the next attempt starts clean rather than
            // reusing a handle the portal has already torn down.
            session = opened
            return .granted(nodeID: first.nodeID)
        } catch PortalSession.Failure.cancelled {
            return .cancelled
        } catch {
            return .failed("\(error)")
        }
    }

    /// Open a PipeWire descriptor on the negotiated session — what
    /// `PortalCaptureEncoder` calls at every start, including after a restart.
    ///
    /// Synchronous on purpose: the capture factory that calls it is not async,
    /// and this is a local D-Bus round trip rather than a dialog.
    func openPipeWireFileDescriptor() throws -> Int32 {
        try queue.sync {
            guard let session else {
                throw PortalSession.Failure.portalError("no negotiated portal session")
            }
            return try session.openPipeWireFileDescriptor()
        }
    }

    /// End the session, which is what makes the compositor drop its "your
    /// screen is being shared" indicator. Idempotent.
    func close() {
        queue.sync {
            session?.close()
            session = nil
        }
    }
}
