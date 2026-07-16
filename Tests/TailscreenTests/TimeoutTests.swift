import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

/// Unit tests for the two timeout wrappers: `withTimeout` (task-group race,
/// used around tsnet bring-up) and `TailscalePeerDiscovery.withWatchdog`
/// (detached-task + DispatchQueue watchdog, used around blocking C calls).
final class TimeoutTests: XCTestCase {

    private struct MarkerError: Error {}

    // MARK: - withTimeout

    func testReturnsResultWhenOperationBeatsDeadline() async throws {
        let value = try await withTimeout(seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testThrowsTimeoutErrorWhenOperationHangs() async {
        do {
            _ = try await withTimeout(seconds: 0.05) { () -> Int in
                try await Task.sleep(for: .seconds(30))
                return 1
            }
            XCTFail("expected TimeoutError")
        } catch is TimeoutError {
            // expected
        } catch {
            XCTFail("expected TimeoutError, got \(error)")
        }
    }

    func testPropagatesOperationError() async {
        do {
            _ = try await withTimeout(seconds: 5) { () -> Int in
                throw MarkerError()
            }
            XCTFail("expected MarkerError")
        } catch is MarkerError {
            // expected
        } catch {
            XCTFail("expected MarkerError, got \(error)")
        }
    }

    // MARK: - withWatchdog

    func testWatchdogReturnsResultWhenOperationBeatsDeadline() async throws {
        let value = try await TailscalePeerDiscovery.withWatchdog(seconds: 5) { "ok" }
        XCTAssertEqual(value, "ok")
    }

    func testWatchdogThrowsTimeoutErrorWhenOperationHangs() async {
        do {
            _ = try await TailscalePeerDiscovery.withWatchdog(seconds: 0.05) { () -> Int in
                try await Task.sleep(for: .seconds(30))
                return 1
            }
            XCTFail("expected TimeoutError")
        } catch is TimeoutError {
            // expected
        } catch {
            XCTFail("expected TimeoutError, got \(error)")
        }
    }

    func testWatchdogPropagatesOperationError() async {
        do {
            _ = try await TailscalePeerDiscovery.withWatchdog(seconds: 5) { () -> Int in
                throw MarkerError()
            }
            XCTFail("expected MarkerError")
        } catch is MarkerError {
            // expected
        } catch {
            XCTFail("expected MarkerError, got \(error)")
        }
    }

    func testWatchdogSurfacesCallerCancellation() async {
        let task = Task {
            try await TailscalePeerDiscovery.withWatchdog(seconds: 30) { () -> Int in
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}
