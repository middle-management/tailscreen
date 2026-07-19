import XCTest

@testable import SDLKit

/// Proves the SDL2 wrapper actually *runs* — window + renderer + streaming YUV
/// texture upload + present — on whatever platform CI builds it. Runs headless
/// against SDL's **dummy** video driver (no display server needed); the dummy
/// driver falls back to SDL's software renderer, which still performs real
/// YUV→RGB texture uploads, so the smoke test genuinely exercises the render
/// path rather than a no-op.
final class VideoWindowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Force the headless driver even if the harness didn't export it, so
        // the suite never depends on a real display / window server.
        setenv("SDL_VIDEODRIVER", "dummy", 1)
    }

    /// A packed 8-bit planar YUV 4:2:0 frame filled with one solid colour.
    private func solidFrame(
        width: Int, height: Int, y: UInt8 = 128, u: UInt8 = 128, v: UInt8 = 128
    ) -> (y: [UInt8], u: [UInt8], v: [UInt8]) {
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        return (
            [UInt8](repeating: y, count: width * height),
            [UInt8](repeating: u, count: chromaWidth * chromaHeight),
            [UInt8](repeating: v, count: chromaWidth * chromaHeight)
        )
    }

    func testCreatePresentAndRecreateTexture() throws {
        let window = try SDL.VideoWindow(title: "SDLKit test", width: 64, height: 48)

        // First frame at the creation size.
        let first = solidFrame(width: 64, height: 48, y: 200, u: 90, v: 60)
        XCTAssertNoThrow(
            try window.present(width: 64, height: 48, yPlane: first.y, uPlane: first.u, vPlane: first.v)
        )

        // A differently sized frame must force a texture recreation and still
        // upload + present cleanly — the mid-stream resolution-change path.
        let second = solidFrame(width: 32, height: 32, y: 40, u: 200, v: 150)
        XCTAssertNoThrow(
            try window.present(width: 32, height: 32, yPlane: second.y, uPlane: second.u, vPlane: second.v)
        )

        // Pumping the event queue on a headless window reports no close request.
        XCTAssertFalse(window.pollShouldClose())
    }

    func testOddDimensionsChromaRounding() throws {
        // Odd width/height exercise the (n + 1) / 2 chroma-plane rounding on
        // both the wrapper's guard and the pitch it hands SDL.
        let window = try SDL.VideoWindow(title: "SDLKit odd", width: 65, height: 33)
        let frame = solidFrame(width: 65, height: 33)
        XCTAssertNoThrow(
            try window.present(width: 65, height: 33, yPlane: frame.y, uPlane: frame.u, vPlane: frame.v)
        )
    }

    func testUndersizedPlaneRejected() throws {
        let window = try SDL.VideoWindow(title: "SDLKit short", width: 64, height: 48)
        // A Y plane one row short must be rejected before any pointer reaches
        // SDL, not read out of bounds.
        let short = [UInt8](repeating: 0, count: 64 * 47)
        let chroma = [UInt8](repeating: 0, count: 32 * 24)
        XCTAssertThrowsError(
            try window.present(width: 64, height: 48, yPlane: short, uPlane: chroma, vPlane: chroma)
        ) { error in
            XCTAssertTrue(error is SDL.Error)
        }
    }
}
