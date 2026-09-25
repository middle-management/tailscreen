import AppKit
import Foundation

/// User-facing error model. Surfaced via the menubar's alert sheet with an
/// optional inline action button and a copy-details affordance. Codes
/// (`TS-SCREEN-001`, …) are stable identifiers for bug reports.
struct AppError: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// `TS-<DOMAIN>-<NNN>` — domains so far: SCREEN, NET, VOICE, AUTH,
    /// GENERIC.
    let code: String
    /// Short title shown as the alert's heading. ~6 words.
    let title: String
    /// Detailed message body. Plain prose; users see this verbatim.
    let message: String
    /// Optional underlying `Error` description, in copy-details only (not
    /// the alert body).
    let underlying: String?
    /// Optional inline action button; `handler` runs on the main actor.
    let action: AppErrorAction?

    static func == (lhs: AppError, rhs: AppError) -> Bool {
        lhs.id == rhs.id
    }

    /// Dump for the alert's Copy Details button.
    func copyableDetails() -> String {
        var lines: [String] = []
        lines.append("Code: \(code)")
        lines.append("Title: \(title)")
        lines.append("Message: \(message)")
        if let underlying, !underlying.isEmpty {
            lines.append("Underlying: \(underlying)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Inline action attached to an `AppError`. `handler` is `@MainActor`
/// because it ultimately touches UI state.
struct AppErrorAction: Sendable {
    let title: String
    let handler: @MainActor @Sendable () -> Void
}

// MARK: - Common error constructors

extension AppError {
    /// SCStream bring-up exceeded the 10s start watchdog. Usually a
    /// first-time permission grant on a busy machine.
    static func screenCaptureStartTimeout() -> AppError {
        AppError(
            code: "TS-SCREEN-002",
            title: L("Couldn't Start Sharing"),
            message:
                L(
                    "macOS didn't return shareable screens in time. If this is the first time you've shared, grant Tailscreen permission in System Settings → Privacy & Security → Screen Recording, then try again."
                ),
            underlying: nil,
            action: AppErrorAction(title: L("Open System Settings")) {
                ScreenCapture.openScreenRecordingSettings()
            }
        )
    }

    /// replayd's per-bundle slot wedged in a state we can't recover
    /// from in-process. Only fix is to restart the app.
    static func screenCaptureBundlePoisoned() -> AppError {
        AppError(
            code: "TS-SCREEN-003",
            title: L("Restart Required"),
            message:
                L(
                    "macOS's screen-recording daemon is in a stuck state for Tailscreen and won't deliver any more frames until the app restarts. This usually follows a startCapture timeout or a stream interruption. Quit Tailscreen (⌘Q) and reopen — sharing will work again."
                ),
            underlying: nil,
            action: nil
        )
    }

    /// startCapture acked but no samples arrived inside the first-
    /// frame window. Frequently caused by a parallel Tailscreen
    /// instance still owning the slot.
    static func screenCaptureNoFrames() -> AppError {
        AppError(
            code: "TS-SCREEN-004",
            title: L("Couldn't Start Sharing"),
            message:
                L(
                    "macOS accepted the screen-capture request but never delivered any frames. This usually means another Tailscreen process is already sharing — quit other instances and try again. If the problem persists, run `killall replayd` in Terminal (macOS will auto-restart it) or reboot."
                ),
            underlying: nil,
            action: nil
        )
    }

    /// Catch-all for screen capture bring-up failures we don't have
    /// a more specific code for.
    static func screenCaptureGeneric(_ underlying: Error) -> AppError {
        AppError(
            code: "TS-SCREEN-099",
            title: L("Couldn't Start Sharing"),
            message: underlying.localizedDescription,
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// Outbound viewer connect() failed at the transport level.
    static func connectionFailed(host: String, underlying: Error) -> AppError {
        AppError(
            code: "TS-NET-001",
            title: L("Connection Failed"),
            message: L("Could not connect to \(host): \(underlying.localizedDescription)"),
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// Peer discovery probe failed.
    static func discoveryFailed(_ underlying: Error) -> AppError {
        AppError(
            code: "TS-NET-002",
            title: L("Discovery Failed"),
            message: underlying.localizedDescription,
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// User asked to discover peers without a Tailscale node up yet.
    static func discoveryUnauthenticated() -> AppError {
        AppError(
            code: "TS-NET-003",
            title: L("Discovery Failed"),
            message: L("Sign in with Tailscale first to discover other Tailscreen instances on your tailnet."),
            underlying: nil,
            action: nil
        )
    }

    /// Sending a request-to-share metadata message failed.
    static func requestToShareFailed(peer: String, underlying: Error) -> AppError {
        AppError(
            code: "TS-NET-004",
            title: L("Request Failed"),
            message: L("Could not send request to \(peer): \(underlying.localizedDescription)"),
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// VoiceChannel / MicCapture bring-up failed at session start.
    static func voiceInitFailed(_ underlying: Error) -> AppError {
        AppError(
            code: "TS-VOICE-001",
            title: L("Voice Init Failed"),
            message:
                L(
                    "Voice could not be initialized: \(underlying.localizedDescription). Voice will be unavailable for this share session."
                ),
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// Viewer's voice channel bring-up failed after HELLO_ACK.
    static func voiceViewerInitFailed(_ underlying: Error) -> AppError {
        AppError(
            code: "TS-VOICE-002",
            title: L("Voice Init Failed"),
            message: underlying.localizedDescription,
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// Toggle mic but no active voice session — and none on the way, which
    /// `AppState.toggleMic` checks first: during bring-up this condition
    /// resolves itself in seconds and is not worth an alert.
    static func voiceNotReady() -> AppError {
        AppError(
            code: "TS-VOICE-003",
            title: L("Voice Not Ready"),
            // Viewing counts. The old wording said "during an active share",
            // which reads as sharer-only and is wrong — a viewer has voice
            // too, and a viewer is who is most likely to reach for the mic.
            message: L("Voice is available while you are sharing or viewing a screen."),
            underlying: nil,
            action: nil
        )
    }

    /// MicCapture.enableCapture threw — usually missing mic permission.
    static func microphoneUnavailable(_ underlying: Error) -> AppError {
        AppError(
            code: "TS-VOICE-004",
            title: L("Microphone Unavailable"),
            message:
                L(
                    "Tailscreen could not start the microphone: \(underlying.localizedDescription). Check System Settings → Privacy & Security → Microphone."
                ),
            underlying: String(describing: underlying),
            action: AppErrorAction(title: L("Open System Settings")) {
                let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                if let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            }
        )
    }

    /// Tailscale interactive login failed.
    static func loginFailed(_ underlying: Error) -> AppError {
        AppError(
            code: "TS-AUTH-001",
            title: L("Login Failed"),
            message: L("Failed to log in: \(underlying.localizedDescription)"),
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// Sign-out failed.
    static func signOutFailed(_ underlying: Error) -> AppError {
        AppError(
            code: "TS-AUTH-002",
            title: L("Sign Out Failed"),
            message: underlying.localizedDescription,
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// startSharing's catch-all when none of the more specific paths
    /// matched.
    static func sharingGeneric(_ underlying: Error) -> AppError {
        AppError(
            code: "TS-SCREEN-100",
            title: L("Error"),
            message: L("Failed to start sharing: \(underlying.localizedDescription)"),
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// A signed-out (link-only) share was asked for while Settings → Link
    /// sharing is off. Normally unreachable — the welcome pane hides its
    /// button behind the same gate — but Settings can change under an open
    /// picker.
    static func linkSharingDisabled() -> AppError {
        AppError(
            code: "TS-LINK-001",
            title: L("Link Sharing Is Off"),
            message:
                L(
                    "Sharing without signing in works over a share link, and link sharing is turned off in Settings. Turn it on under Settings → Link sharing, or sign in to share over your tailnet."
                ),
            underlying: nil,
            action: nil
        )
    }

    /// A guest-only share's bring-up failed before capture — the relay
    /// bootstrap or the guest node, not the screen.
    static func linkShareStartFailed(_ underlying: Error) -> AppError {
        AppError(
            code: "TS-LINK-002",
            title: L("Couldn't Start Sharing"),
            message: L("The share link couldn't be created. Check the network and try again."),
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// A join-by-link that never got off the ground: the relay bootstrap
    /// for an expired, revoked or mistyped token.
    ///
    /// The bootstrap has no deadline of its own — a token names a relay and
    /// a node key, and a dial at a node that is gone simply waits. Without
    /// this the hub sat on a spinner indefinitely; one rc.16 bundle shows a
    /// viewer window open for three and a half minutes on a connection that
    /// had given up after fifteen seconds.
    static func linkJoinUnreachable() -> AppError {
        AppError(
            code: "TS-LINK-003",
            title: L("Couldn't Join That Link"),
            message:
                L(
                    "Nothing answered at that share link. It may have expired, been replaced by a new link, or the sharer may have stopped sharing. Ask for a fresh link and try again."
                ),
            underlying: nil,
            action: nil
        )
    }

    /// Legacy free-form alert constructor. Used by the `showAlert
    /// Message(title:message:)` shim so existing call sites keep
    /// working without forcing every site to define its own AppError
    /// case.
    static func legacy(title: String, message: String) -> AppError {
        AppError(
            code: "TS-GENERIC-001",
            title: title,
            message: message,
            underlying: nil,
            action: nil
        )
    }
}
