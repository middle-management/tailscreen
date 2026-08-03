import XCTest

@testable import TailscreenProtocol

/// The sharer's arm/disarm decisions, with a fake surface.
///
/// No window, no compositor, no message pump — which is the point: every case
/// below is a way to strand a person behind a fullscreen window that eats
/// clicks, and none of them can be reproduced on the machine that would suffer
/// it.
final class SharerDrawingLatchTests: XCTestCase {
    /// Records what the host was told to do, so the ORDER and the presence of
    /// the disarm can be asserted — not just the end state, which is what a
    /// half-armed surface agrees with.
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

    /// Changing pen mid-draw must not tear the surface down and put it back up:
    /// on both hosts that means dropping and re-taking keyboard focus, and the
    /// re-take is the step that is allowed to fail.
    func testSwitchingToolsDoesNotDisarmInBetween() {
        var latch = SharerDrawingLatch()
        let surface = FakeSurface()

        latch.select(.pen, surface: surface.handle)
        XCTAssertTrue(latch.select(.arrow, surface: surface.handle))

        XCTAssertEqual(latch.activeTool, .arrow)
        XCTAssertEqual(surface.calls, [.pen, .arrow])
    }

    /// The safety property. A host that could not take the keyboard may still
    /// have a window up eating clicks, and it cannot tell us — so the refusal
    /// path issues a disarm regardless.
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

        // And a later success clears it, so a stale sentence does not sit under
        // a toolbar that is now working.
        surface.answer = .armed
        XCTAssertTrue(latch.select(.pen, surface: surface.handle))
        XCTAssertNil(latch.refusal)
        XCTAssertEqual(latch.activeTool, .pen)
    }

    /// The other half of the safety property, and the one a conditional
    /// implementation gets wrong: if an arm half-succeeded, this latch thinks
    /// nothing is armed, and a teardown that trusts it leaves the window up
    /// after the share has ended.
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

    /// The whole point of naming `keep`: a tool change must not rebuild the
    /// surface, because rebuilding means letting go of keyboard focus and
    /// asking for it again — and asking is the step allowed to fail. Switching
    /// from the pen to the arrow would then silently end drawing, blaming a
    /// keyboard the sharer never touched.
    func testSwitchingToolsKeepsTheSurfaceThatAlreadyHasFocus() {
        XCTAssertEqual(
            SharerDrawingSurfacePlan.plan(tool: .arrow, hasSurface: true, hasRegion: true), .keep)
    }

    func testArmingWithoutASurfaceBuildsOne() {
        XCTAssertEqual(
            SharerDrawingSurfacePlan.plan(tool: .pen, hasSurface: false, hasRegion: true), .create)
    }

    /// No known geometry means a stroke has nothing to be normalized against,
    /// so it is refused rather than drawn somewhere plausible and wrong — the
    /// same answer remote control and viewer annotations give to the same
    /// question.
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

    /// Escape, and the surface reporting it lost the keyboard, are the same
    /// decision: the way out is no longer reachable, so stop.
    func testReleaseDisarms() {
        var latch = SharerDrawingLatch()
        let surface = FakeSurface()

        latch.select(.rectangle, surface: surface.handle)
        latch.release(surface: surface.handle)

        XCTAssertNil(latch.activeTool)
        XCTAssertEqual(surface.calls, [.rectangle, nil])
    }
}
