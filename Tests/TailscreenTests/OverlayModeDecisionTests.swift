import XCTest

@testable import Tailscreen

/// Unit tests for `AppState.overlayMode(for:)` — the pure decision that
/// projects a `PickerSelection` onto the `SharerOverlayWindow.Mode` the
/// sharer overlay is (re)built with. Exercised live by both the share
/// entry point and the mid-share "Change Source…" flow (which must
/// rebuild the overlay because its mode is immutable); neither path can
/// run on CI, so the mapping is pinned down here instead. All-@MainActor,
/// no UI — the enum is constructed but no panel is created.
final class OverlayModeDecisionTests: XCTestCase {
    @MainActor
    private func makeSelection(
        kind: PickerSelection.Kind,
        displayID: UInt32? = nil,
        windowID: UInt32? = nil,
        bundleIDs: [String] = []
    ) -> PickerSelection {
        PickerSelection(kind: kind, displayID: displayID, windowID: windowID, bundleIDs: bundleIDs)
    }

    @MainActor
    func testNilSelectionFallsBackToFullDisplay() {
        // Legacy entry points / decode failures degrade to the
        // full-display overlay rather than refusing to render.
        guard case .display(let id) = AppState.overlayMode(for: nil) else {
            return XCTFail("nil selection should map to .display")
        }
        XCTAssertNil(id)
    }

    @MainActor
    func testDisplaySelectionCarriesDisplayID() {
        let mode = AppState.overlayMode(for: makeSelection(kind: .display, displayID: 42))
        guard case .display(let id) = mode else {
            return XCTFail("display selection should map to .display")
        }
        XCTAssertEqual(id, 42)
    }

    @MainActor
    func testDisplaySelectionWithoutIDStillMapsToDisplay() {
        let mode = AppState.overlayMode(for: makeSelection(kind: .display))
        guard case .display(let id) = mode else {
            return XCTFail("display selection should map to .display")
        }
        XCTAssertNil(id)
    }

    @MainActor
    func testWindowSelectionCarriesWindowID() {
        let mode = AppState.overlayMode(for: makeSelection(kind: .window, windowID: 7))
        guard case .window(let id) = mode else {
            return XCTFail("window selection should map to .window")
        }
        XCTAssertEqual(id, 7)
    }

    @MainActor
    func testWindowSelectionMissingIDFallsBackToFullDisplay() {
        // A window selection whose ID didn't survive the wire hop can't
        // be tracked — full-display overlay is the graceful degradation.
        let mode = AppState.overlayMode(for: makeSelection(kind: .window))
        guard case .display(let id) = mode else {
            return XCTFail("window selection without ID should fall back to .display")
        }
        XCTAssertNil(id)
    }

    @MainActor
    func testApplicationSelectionCarriesAnchorDisplay() {
        let mode = AppState.overlayMode(
            for: makeSelection(kind: .application, displayID: 3, bundleIDs: ["com.example.a"]))
        guard case .application(let displayID) = mode else {
            return XCTFail("application selection should map to .application")
        }
        XCTAssertEqual(displayID, 3)
    }

    @MainActor
    func testApplicationSelectionWithoutDisplayStillMapsToApplication() {
        let mode = AppState.overlayMode(
            for: makeSelection(kind: .application, bundleIDs: ["com.example.a", "com.example.b"]))
        guard case .application(let displayID) = mode else {
            return XCTFail("application selection should map to .application")
        }
        XCTAssertNil(displayID)
    }
}
