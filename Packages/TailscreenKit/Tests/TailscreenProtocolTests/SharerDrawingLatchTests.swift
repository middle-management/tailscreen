import XCTest

@testable import TailscreenProtocol

/// The sharer's arm/disarm decisions, with a fake surface. No window,
/// compositor or message pump: every case is a way to strand a person behind
/// a fullscreen window that eats clicks.
final class SharerDrawingLatchTests: XCTestCase {
    /// Records the ORDER and presence of the disarm, not just end state — a
    /// half-armed surface can agree with the end state alone.
    private final class FakeSurface {
        var calls: [AnnotationTool?] = []
        var answer: SharerDrawingArmResult = .armed

        func handle(_ tool: AnnotationTool?) -> SharerDrawingArmResult {
            calls.append(tool)
            return tool == nil ? .armed : answer
        }
    }

    func testTappingTheArmedToolAgainDisarms() {
        var latch = SharerDrawingLatch()
        let surface = FakeSurface()

        XCTAssertTrue(latch.select(.pen, surface: surface.handle))
        XCTAssertEqual(latch.activeTool, .pen)

        XCTAssertFalse(latch.select(.pen, surface: surface.handle))
        XCTAssertNil(latch.activeTool)
        XCTAssertEqual(surface.calls, [.pen, nil])
    }

    /// Changing tools mid-draw must not tear the surface down and rebuild it:
    /// on both hosts that means dropping and re-taking keyboard focus, and the
    /// re-take can fail.
    func testSwitchingToolsDoesNotDisarmInBetween() {
        var latch = SharerDrawingLatch()
        let surface = FakeSurface()

        latch.select(.pen, surface: surface.handle)
        XCTAssertTrue(latch.select(.arrow, surface: surface.handle))

        XCTAssertEqual(latch.activeTool, .arrow)
        XCTAssertEqual(surface.calls, [.pen, .arrow])
    }

    /// A host that couldn't take the keyboard may still have a window up
    /// eating clicks, and can't tell us — so refusal disarms regardless.
    func testARefusalStillDisarmsTheSurface() {
        var latch = SharerDrawingLatch()
        let surface = FakeSurface()
        surface.answer = .refused(.noKeyboard)

        XCTAssertFalse(latch.select(.pen, surface: surface.handle))

        XCTAssertNil(latch.activeTool)
        XCTAssertEqual(latch.refusal, .noKeyboard)
        XCTAssertEqual(
            surface.calls, [.pen, nil],
            "a refused arm must be followed by a disarm, or a half-armed surface is left up")
    }

    func testRefusalReasonIsCarriedForTheSharerToRead() {
        var latch = SharerDrawingLatch()
        let surface = FakeSurface()
        surface.answer = .refused(.noSurface)

        latch.select(.pen, surface: surface.handle)
        XCTAssertEqual(latch.refusal, .noSurface)

        // A later success clears it, so a stale message doesn't sit under a working toolbar.
        surface.answer = .armed
        XCTAssertTrue(latch.select(.pen, surface: surface.handle))
        XCTAssertNil(latch.refusal)
        XCTAssertEqual(latch.activeTool, .pen)
    }

    /// If an arm half-succeeded, the latch thinks nothing is armed; a
    /// teardown that trusts it leaves the window up after the share ends.
    func testTeardownDisarmsEvenWhenNothingIsArmed() {
        var latch = SharerDrawingLatch()
        let surface = FakeSurface()

        latch.teardown(surface: surface.handle)

        XCTAssertEqual(
            surface.calls, [nil],
            "teardown must disarm unconditionally — it cannot know an arm did not half-succeed")
        XCTAssertNil(latch.activeTool)
    }

    // MARK: Surface lifetime

    /// A tool change must not rebuild the surface: rebuilding means letting go
    /// of keyboard focus and re-asking, and re-asking can fail, silently
    /// ending drawing.
    func testSwitchingToolsKeepsTheSurfaceThatAlreadyHasFocus() {
        XCTAssertEqual(
            SharerDrawingSurfacePlan.plan(tool: .arrow, hasSurface: true, hasRegion: true), .keep)
    }

    func testArmingWithoutASurfaceBuildsOne() {
        XCTAssertEqual(
            SharerDrawingSurfacePlan.plan(tool: .pen, hasSurface: false, hasRegion: true), .create)
    }

    /// No known geometry means a stroke has nothing to normalize against, so
    /// it is refused rather than drawn somewhere plausible and wrong.
    func testNoRegionRefusesRatherThanGuessing() {
        XCTAssertEqual(
            SharerDrawingSurfacePlan.plan(tool: .pen, hasSurface: false, hasRegion: false),
            .refuse(.noSurface))
    }

    func testNoToolReleasesWhateverIsUp() {
        XCTAssertEqual(
            SharerDrawingSurfacePlan.plan(tool: nil, hasSurface: true, hasRegion: true), .release)
        XCTAssertEqual(
            SharerDrawingSurfacePlan.plan(tool: nil, hasSurface: false, hasRegion: false),
            .release)
    }

    /// Escape and the surface losing the keyboard are the same decision: stop.
    func testReleaseDisarms() {
        var latch = SharerDrawingLatch()
        let surface = FakeSurface()

        latch.select(.rectangle, surface: surface.handle)
        latch.release(surface: surface.handle)

        XCTAssertNil(latch.activeTool)
        XCTAssertEqual(surface.calls, [.rectangle, nil])
    }
}
