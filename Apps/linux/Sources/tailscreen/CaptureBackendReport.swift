import Foundation
import TailscreenProtocol

/// `tailscreen --capture-backend-report`: print which capture backend this
/// machine would use, and why.
///
/// Also a CI gate: `CaptureBackendSelection`'s decision logic is unit-tested,
/// but nothing else reads `XDG_SESSION_TYPE` — this covers the wiring, so a
/// regression there (e.g. reading `DISPLAY` again) can't hide behind green
/// unit tests while Wayland users silently fall back to an XWayland root.
///
/// Includes a real portal probe (puts nothing on screen, safe unattended) so
/// the report reflects this machine, not just the environment.
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

    /// Machine-readable on purpose — CI greps these as a contract, not a log.
    private static func describe(_ choice: CaptureBackendSelection.Choice) -> String {
        switch choice {
        case .x11(let display): return "x11(\(display))"
        case .portal: return "portal"
        case .unavailable: return "unavailable"
        }
    }
}
