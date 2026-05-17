import AppKit
import Foundation

/// User-facing error model. Surfaced via the menubar's alert sheet
/// with an optional in-line action button (e.g. "Open System Settings",
/// "Retry") and a copy-details affordance so bug reports come with
/// reproducible context. Codes (`TS-SCREEN-001`, `TS-NET-002`, …) are
/// stable identifiers callers can paste into issue trackers without
/// pasting full stack traces — the human-readable title + message
/// describe the symptom, the code disambiguates the exact path.
struct AppError: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// Stable identifier suitable for logs / bug reports. Format
    /// `TS-<DOMAIN>-<NNN>` — domains so far: SCREEN, NET, VOICE,
    /// AUTH, GENERIC.
    let code: String
    /// Short title shown as the alert's heading. ~6 words.
    let title: String
    /// Detailed message body. Plain prose; users see this verbatim.
    let message: String
    /// Optional underlying `Error` description rolled into the copy-
    /// details payload. Not rendered in the alert body so the UI
    /// stays focused, but the user can paste full details when
    /// reporting.
    let underlying: String?
    /// Optional inline action button. `title` becomes the button
    /// label; `handler` runs on the main actor.
    let action: AppErrorAction?

    static func == (lhs: AppError, rhs: AppError) -> Bool {
        lhs.id == rhs.id
    }

    /// Tab-separated single-string dump for the alert's Copy Details
    /// button. Includes everything that's safe to share publicly —
    /// code, title, message, underlying error.
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

/// Inline action attached to an `AppError`. Kept Sendable-friendly
/// (the handler is `@MainActor` because actions ultimately touch UI
/// state — NSWorkspace, AppState methods, retry closures wrapping
/// async work).
struct AppErrorAction: Sendable {
    let title: String
    let handler: @MainActor @Sendable () -> Void
}

// MARK: - Common error constructors

extension AppError {
    /// User denied Screen Recording or hasn't granted it yet. The
    /// inline action opens System Settings → Privacy & Security →
    /// Screen Recording.
    static func screenRecordingDenied() -> AppError {
        AppError(
            code: "TS-SCREEN-001",
            title: "Screen Recording Permission Required",
            message: "Tailscreen needs Screen Recording permission to share your display. Open System Settings → Privacy & Security → Screen Recording, enable Tailscreen, then try again.",
            underlying: nil,
            action: AppErrorAction(title: "Open System Settings") {
                ScreenCapture.openScreenRecordingSettings()
            }
        )
    }

    /// SCStream bring-up exceeded the 10s start watchdog. Usually a
    /// first-time permission grant on a busy machine.
    static func screenCaptureStartTimeout() -> AppError {
        AppError(
            code: "TS-SCREEN-002",
            title: "Couldn't Start Sharing",
            message: "macOS didn't return shareable screens in time. If this is the first time you've shared, grant Tailscreen permission in System Settings → Privacy & Security → Screen Recording, then try again.",
            underlying: nil,
            action: AppErrorAction(title: "Open System Settings") {
                ScreenCapture.openScreenRecordingSettings()
            }
        )
    }

    /// replayd's per-bundle slot wedged in a state we can't recover
    /// from in-process. Only fix is to restart the app.
    static func screenCaptureBundlePoisoned() -> AppError {
        AppError(
            code: "TS-SCREEN-003",
            title: "Restart Required",
            message: "macOS's screen-recording daemon is in a stuck state for Tailscreen and won't deliver any more frames until the app restarts. This usually follows a startCapture timeout or a stream interruption. Quit Tailscreen (⌘Q) and reopen — sharing will work again.",
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
            title: "Couldn't Start Sharing",
            message: "macOS accepted the screen-capture request but never delivered any frames. This usually means another Tailscreen process is already sharing — quit other instances and try again. If the problem persists, run `killall replayd` in Terminal (macOS will auto-restart it) or reboot.",
            underlying: nil,
            action: nil
        )
    }

    /// Catch-all for screen capture bring-up failures we don't have
    /// a more specific code for.
    static func screenCaptureGeneric(_ underlying: Error) -> AppError {
        AppError(
            code: "TS-SCREEN-099",
            title: "Couldn't Start Sharing",
            message: underlying.localizedDescription,
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// Outbound viewer connect() failed at the transport level.
    static func connectionFailed(host: String, underlying: Error) -> AppError {
        AppError(
            code: "TS-NET-001",
            title: "Connection Failed",
            message: "Could not connect to \(host): \(underlying.localizedDescription)",
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// Peer discovery probe failed.
    static func discoveryFailed(_ underlying: Error) -> AppError {
        AppError(
            code: "TS-NET-002",
            title: "Discovery Failed",
            message: underlying.localizedDescription,
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// User asked to discover peers without a Tailscale node up yet.
    static func discoveryUnauthenticated() -> AppError {
        AppError(
            code: "TS-NET-003",
            title: "Discovery Failed",
            message: "Sign in with Tailscale first to discover other Tailscreen instances on your tailnet.",
            underlying: nil,
            action: nil
        )
    }

    /// Sending a request-to-share metadata message failed.
    static func requestToShareFailed(peer: String, underlying: Error) -> AppError {
        AppError(
            code: "TS-NET-004",
            title: "Request Failed",
            message: "Could not send request to \(peer): \(underlying.localizedDescription)",
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// VoiceChannel / MicCapture bring-up failed at session start.
    static func voiceInitFailed(_ underlying: Error) -> AppError {
        AppError(
            code: "TS-VOICE-001",
            title: "Voice Init Failed",
            message: "Voice could not be initialized: \(underlying.localizedDescription). Voice will be unavailable for this share session.",
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// Viewer's voice channel bring-up failed after HELLO_ACK.
    static func voiceViewerInitFailed(_ underlying: Error) -> AppError {
        AppError(
            code: "TS-VOICE-002",
            title: "Voice Init Failed",
            message: underlying.localizedDescription,
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// Toggle mic but no active voice session.
    static func voiceNotReady() -> AppError {
        AppError(
            code: "TS-VOICE-003",
            title: "Voice Not Ready",
            message: "Voice is only available during an active share.",
            underlying: nil,
            action: nil
        )
    }

    /// MicCapture.enableCapture threw — usually missing mic permission.
    static func microphoneUnavailable(_ underlying: Error) -> AppError {
        AppError(
            code: "TS-VOICE-004",
            title: "Microphone Unavailable",
            message: "Tailscreen could not start the microphone: \(underlying.localizedDescription). Check System Settings → Privacy & Security → Microphone.",
            underlying: String(describing: underlying),
            action: AppErrorAction(title: "Open System Settings") {
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
            title: "Login Failed",
            message: "Failed to log in: \(underlying.localizedDescription)",
            underlying: String(describing: underlying),
            action: nil
        )
    }

    /// Sign-out failed.
    static func signOutFailed(_ underlying: Error) -> AppError {
        AppError(
            code: "TS-AUTH-002",
            title: "Sign Out Failed",
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
            title: "Error",
            message: "Failed to start sharing: \(underlying.localizedDescription)",
            underlying: String(describing: underlying),
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
