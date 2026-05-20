import Foundation
import XCTest

@testable import Tailscreen

/// Subprocess-lifecycle sanity check for `Tailscreen --picker-helper`. The
/// picker UI itself is interactive and can't be meaningfully driven from a
/// test without accessibility automation, so this only verifies the spawn /
/// terminate plumbing works — enough to catch regressions where the helper
/// crashes on launch or fails to receive SIGTERM cleanly.
///
/// Local-only: needs a WindowServer + accessory NSApp to come up. Skipped on
/// GitHub Actions runners.
final class PickerHelperSmokeTests: XCTestCase {
    func testPickerHelperSpawnsAndTerminates() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(
            env["CI"] == "true" || env["GITHUB_ACTIONS"] == "true",
            "Picker helper needs WindowServer + accessory NSApp; not viable on CI."
        )

        let binary = try TailscreenE2E.resolveTailscreenBinary()
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["--picker-helper"]
        proc.standardOutput = Pipe()
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        addTeardownBlock {
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                proc.waitUntilExit()
            }
        }

        // Let the helper actually start (NSApp.run, picker.present()).
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(
            proc.isRunning,
            "picker helper should still be running before SIGTERM"
        )

        proc.terminate()
        // Generous teardown window — UI termination can be slow.
        for _ in 0..<30 {
            if !proc.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        proc.waitUntilExit()

        // SIGTERM should produce a non-zero exit (either an explicit
        // non-zero code or an uncaught-signal termination).
        let signalled = proc.terminationReason == .uncaughtSignal
        let nonZero = proc.terminationStatus != 0
        XCTAssertTrue(
            signalled || nonZero,
            "picker helper exited unexpectedly cleanly under SIGTERM"
        )
    }

    /// Verify the `TAILSCREEN_AUTOSHARE_DISPLAY=1` short-circuit emits a
    /// framed `PickerSelection` and exits 0 without ever touching the
    /// picker UI. Doesn't need WindowServer, so it can run anywhere the
    /// binary exists.
    func testAutoShareDisplayShortCircuit() async throws {
        let binary = try TailscreenE2E.resolveTailscreenBinary()
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["--picker-helper"]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        var procEnv = ProcessInfo.processInfo.environment
        procEnv["TAILSCREEN_AUTOSHARE_DISPLAY"] = "1"
        proc.environment = procEnv

        try proc.run()
        proc.waitUntilExit()

        XCTAssertEqual(proc.terminationStatus, 0, "auto-share should exit 0")

        // Read framed payload off stdout: [len:4 BE][JSON bytes].
        let bytes = stdout.fileHandleForReading.readDataToEndOfFile()
        guard bytes.count >= 4 else {
            XCTFail("auto-share produced no framed output")
            return
        }
        let len =
            (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        XCTAssertGreaterThan(len, 0, "framed payload should be non-empty")
        let payload = bytes.subdata(in: 4..<min(bytes.count, 4 + Int(len)))
        let selection = try JSONDecoder().decode(PickerSelection.self, from: payload)
        XCTAssertEqual(selection.kind, .display)
        XCTAssertNotNil(selection.displayID)
    }
}
