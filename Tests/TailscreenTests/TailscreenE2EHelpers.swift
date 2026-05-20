import Foundation
import TailscaleKit
import XCTest

@testable import Tailscreen

/// Shared bring-up for the screen-share E2E tests. Factors out the
/// authKey / controlURL / temp-state-dir dance so each test file isn't
/// reinventing the pattern in `TailscaleConnectivityTests`.
enum TailscreenE2E {
    struct EnvConfig {
        let authKey: String
        let controlURL: String
    }

    /// Read TAILSCREEN_TS_AUTHKEY (or TS_AUTHKEY) and TAILSCREEN_TS_CONTROL_URL
    /// (or TS_CONTROL_URL); skip the calling test if no auth key is present.
    /// Same env-var resolution rules as `TailscaleConnectivityTests:23-28`.
    static func loadEnvOrSkip(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> EnvConfig {
        let env = ProcessInfo.processInfo.environment
        let authKey = env["TAILSCREEN_TS_AUTHKEY"] ?? env["TS_AUTHKEY"] ?? ""
        try XCTSkipIf(
            authKey.isEmpty,
            "Set TAILSCREEN_TS_AUTHKEY (or run scripts/e2e-test.sh for local headscale).",
            file: file, line: line
        )
        let controlURL =
            env["TAILSCREEN_TS_CONTROL_URL"]
            ?? env["TS_CONTROL_URL"]
            ?? kDefaultControlURL
        return EnvConfig(authKey: authKey, controlURL: controlURL)
    }

    /// Create a unique temp tree with `server/` and `client/` subdirectories,
    /// register teardown to remove it, and return both paths.
    static func makeStateDirs(
        testCase: XCTestCase,
        label: String
    ) throws -> (server: String, client: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscreen-\(label)-\(UUID().uuidString)")
        let serverDir = tmp.appendingPathComponent("server").path
        let clientDir = tmp.appendingPathComponent("client").path
        try FileManager.default.createDirectory(
            atPath: serverDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: clientDir, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: tmp)
        }
        return (serverDir, clientDir)
    }

    /// Locate `.build/<config>/Tailscreen` so an XCTest can spawn the real
    /// `--capture-helper` or `--picker-helper` child. `Bundle.main` inside
    /// xctest points at the xctest harness, not Tailscreen, so we walk up
    /// from the test bundle and look for the SwiftPM build directory.
    static func resolveTailscreenBinary() throws -> URL {
        // The xctest bundle lives at .build/<config>/<Name>PackageTests.xctest;
        // its enclosing directory is .build/<config>, which is where SwiftPM
        // also drops the Tailscreen executable.
        let xctest = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
        let baseDir: URL
        if let xctest {
            baseDir = xctest.bundleURL.deletingLastPathComponent()
        } else {
            baseDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/debug")
        }
        let candidate = baseDir.appendingPathComponent("Tailscreen")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw NSError(
                domain: "TailscreenE2E", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not find Tailscreen binary at \(candidate.path). Run `make build` first."
                ])
        }
        return candidate
    }

    /// Short, unique, role-prefixed hostname for tailnet nodes spun up in tests.
    static func makeHostname(_ role: String) -> String {
        "ts-\(role)-\(UUID().uuidString.prefix(6))"
    }
}
