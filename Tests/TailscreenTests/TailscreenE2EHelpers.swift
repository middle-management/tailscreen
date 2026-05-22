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

    /// Like `makeStateDirs` but for an arbitrary set of named tsnet state
    /// dirs under one temp tree (e.g. server + two viewers). Registers
    /// teardown to remove the whole tree.
    static func makeStateDirs(
        testCase: XCTestCase,
        label: String,
        names: [String]
    ) throws -> [String: String] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscreen-\(label)-\(UUID().uuidString)")
        var paths: [String: String] = [:]
        for name in names {
            let dir = tmp.appendingPathComponent(name).path
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            paths[name] = dir
        }
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: tmp)
        }
        return paths
    }

    /// Short, unique, role-prefixed hostname for tailnet nodes spun up in tests.
    static func makeHostname(_ role: String) -> String {
        "ts-\(role)-\(UUID().uuidString.prefix(6))"
    }

    /// Encode a handful of frames of a synthetic pixel buffer to produce
    /// realistic AVCC NAL units + parameter sets for tests that inject into
    /// the server's broadcast path (no capture-helper). Skips the calling
    /// test if VideoToolbox produces no output (virtualized runners without
    /// hardware video acceleration).
    static func encodeSyntheticAUs(
        width: Int = 640,
        height: Int = 480,
        frames: Int = 30
    ) async throws -> (params: CodecParameterSets, aus: [(data: Data, isKey: Bool)]) {
        let pixelBuffer = try VideoCodecTests.makePixelBuffer(width: width, height: height)
        let encoder = VideoEncoder()
        try encoder.setup(width: width, height: height, fps: 30, bitsPerPixel: 0.2)
        defer { encoder.shutdown() }

        let collector = AUCollector()
        encoder.onParameterSets = { collector.recordParams($0) }
        encoder.onEncodedData = { data, isKey in collector.recordAU(data: data, isKey: isKey) }
        for _ in 0..<frames {
            encoder.encode(pixelBuffer: pixelBuffer)
        }
        // Let VideoToolbox flush its async output queue.
        try await Task.sleep(for: .milliseconds(1500))
        let snapshot = collector.snapshot()
        guard let params = snapshot.params, !snapshot.aus.isEmpty else {
            throw XCTSkip(
                "VideoToolbox produced no output — likely a virtualized environment without "
                    + "hardware video acceleration.")
        }
        return (params, snapshot.aus)
    }
}

/// Thread-safe collector for VideoEncoder's async output. Keeps every
/// access unit (not just the first keyframe) so injection tests can replay
/// a short GOP through the server's broadcast path.
final class AUCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var params: CodecParameterSets?
    private var aus: [(data: Data, isKey: Bool)] = []

    func recordParams(_ p: CodecParameterSets) {
        lock.lock()
        defer { lock.unlock() }
        params = p
    }

    func recordAU(data: Data, isKey: Bool) {
        lock.lock()
        defer { lock.unlock() }
        aus.append((data, isKey))
    }

    func snapshot() -> (params: CodecParameterSets?, aus: [(data: Data, isKey: Bool)]) {
        lock.lock()
        defer { lock.unlock() }
        return (params, aus)
    }
}
