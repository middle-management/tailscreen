import XCTest

@testable import Tailscreen

@MainActor
final class TailscaleScreenShareClientLifecycleTests: XCTestCase {
    func testDisconnectBeforeTailnetDialPermanentlyCancelsClient() async {
        let client = TailscaleScreenShareClient(renderer: MetalViewerRenderer())

        async let firstDisconnect: Void = client.disconnect()
        async let overlappingDisconnect: Void = client.disconnect()
        _ = await (firstDisconnect, overlappingDisconnect)

        do {
            try await client.connect(to: "100.64.0.7")
            XCTFail("A disconnected one-shot client must not start a later dial")
        } catch is CancellationError {
            // Expected: no node or listener was created.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testDisconnectBeforeGuestDialPermanentlyCancelsClient() async {
        let client = TailscaleScreenShareClient(renderer: MetalViewerRenderer())
        await client.disconnect()

        do {
            try await client.connectGuest(token: "tc-test-token")
            XCTFail("A disconnected one-shot client must not start a later guest dial")
        } catch is CancellationError {
            // Expected: no guest tunnel or listener was created.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
}
