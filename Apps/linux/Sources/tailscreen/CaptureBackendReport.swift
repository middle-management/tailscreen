import Foundation
import TailscreenProtocol

/// `tailscreen --capture-backend-report`: print which capture backend this
/// machine would use, and why.
///
/// A diagnostic first and a CI gate second, and it earns both jobs by covering
/// the one piece of `CaptureBackendSelection` that its unit tests structurally
/// cannot: the **wiring**. The pure decision is tested exhaustively, but a
/// decision fed the wrong environment is just as wrong as a wrong decision, and
/// nothing else in this app reads `XDG_SESSION_TYPE` — so a regression there
/// (reading `DISPLAY` again, say) would leave every unit test green while
/// Wayland users silently went back to sharing an XWayland root.
///
/// The portal probe is deliberately included. It puts nothing on screen, so
/// this is safe to run unattended, and its result is what makes the report the
/// truth about this machine rather than a restatement of the environment.
enum CaptureBackendReport {
    static let marker = "CAPTURE_BACKEND_REPORT"

    static func run() {
        let processEnvironment = ProcessInfo.processInfo.environment
        let session = CaptureBackendSelection.sessionKind(fromEnvironment: processEnvironment)
        let portal = PortalSessionHost().probeAvailability()
        let environment = CaptureBackendSelection.Environment(
            session: session,
            x11Display: processEnvironment["DISPLAY"],
            portalAvailable: portal)

        var lines: [String] = [
            "\(marker) session=\(session.rawValue) "
                + "display=\(describe(processEnvironment["DISPLAY"])) portal=\(portal)"
        ]
        for intent in CaptureBackendSelection.Intent.allCases {
            let choice = CaptureBackendSelection.choose(intent: intent, environment: environment)
            lines.append("\(marker) intent=\(name(intent)) backend=\(describe(choice))")
        }
        lines.append(
            "\(marker) canShare=\(CaptureBackendSelection.canShareAnything(environment: environment))"
        )

        let text = lines.joined(separator: "\n") + "\n"
        FileHandle.standardError.write(Data(text.utf8))
        print(text, terminator: "")
        exit(0)
    }

    private static func name(_ intent: CaptureBackendSelection.Intent) -> String {
        switch intent {
        case .entireScreen: return "entire-screen"
        case .windowOrApp: return "window-or-app"
        }
    }

    private static func describe(_ display: String?) -> String {
        guard let display, !display.isEmpty else { return "none" }
        return display
    }

    /// Machine-readable on purpose — CI greps these, so they are a contract,
    /// not a log line. A reason string would be unstable; the backend name is
    /// the assertion.
    private static func describe(_ choice: CaptureBackendSelection.Choice) -> String {
        switch choice {
        case .x11(let display): return "x11(\(display))"
        case .portal: return "portal"
        case .unavailable: return "unavailable"
        }
    }
}
