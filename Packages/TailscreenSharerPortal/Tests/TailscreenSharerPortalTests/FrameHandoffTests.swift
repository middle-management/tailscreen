import Foundation
import XCTest

@testable import TailscreenSharerPortal

/// `FrameHandoff` — the buffer hand-off between PipeWire's thread and the
/// encode thread. The portal backend can't be gated end to end (a share
/// starts with a consent dialog), so this suite uses real threads and real
/// contention instead — affordable because this type needs no portal,
/// PipeWire, encoder or person at a keyboard.
final class FrameHandoffTests: XCTestCase {

    // MARK: The invariant

    /// The reason this type exists: **the encoder must never read a buffer
    /// the converter is writing.** Driven deterministically rather than by
    /// racing two threads and hoping — the window is narrow enough that a
    /// stress loop scored 0 hits in 3000 iterations against a `publish` with
    /// the `writing` check deleted. So the conversion is stopped mid-write
    /// and `publish` is called from another thread at precisely that moment.
    ///
    /// Verified to catch it: deleting `!writing` from `publish`'s guard makes
    /// this fail.
    func testPublishRefusesToSwapABufferThatIsBeingWritten() {
        let handoff = FrameHandoff(width: 320, height: 180)

        // Sets `backDirty` going into the next write — otherwise nothing for
        // `publish` to be tempted to swap.
        handoff.write { planes in
            fill(planes, with: 1)
            return true
        }

        let midWrite = DispatchSemaphore(value: 0)
        let published = DispatchSemaphore(value: 0)
        let result = PublishResult()

        let reader = Thread {
            midWrite.wait()
            let (planes, isNew) = handoff.publish()
            result.record(isNew: isNew, uniform: isUniform(planes))
            published.signal()
        }
        reader.start()

        handoff.write { planes in
            // Half-written: the first plane is the new value, the rest is not.
            fill(planes, with: 2)
            midWrite.signal()
            published.wait()
            return true
        }

        XCTAssertFalse(
            result.isNew,
            "publish swapped out a buffer the converter was still writing into")
        XCTAssertTrue(result.uniform, "the encoder was handed a torn frame")
    }

    /// The other half: once the write finishes, the frame must become
    /// publishable — a `publish` that never swapped would pass the test
    /// above and starve the encoder forever.
    func testTheFrameBecomesPublishableOnceTheWriteCompletes() {
        let handoff = FrameHandoff(width: 64, height: 64)
        handoff.write { planes in
            fill(planes, with: 9)
            return true
        }
        let (planes, isNew) = handoff.publish()
        XCTAssertTrue(isNew)
        XCTAssertEqual(planes.y.first, 9)
    }

    /// A stress smoke test (not the gate — see the deterministic test above
    /// for why green here proves less than it looks like).
    func testConcurrentWritingAndPublishingDoesNotTearOrDeadlock() {
        let handoff = FrameHandoff(width: 320, height: 180)
        let iterations = 2000
        let done = DispatchSemaphore(value: 0)
        let torn = TornCounter()

        let writer = Thread {
            for index in 0..<iterations {
                handoff.write { planes in
                    fill(planes, with: UInt8(index % 251 + 1))
                    return true
                }
            }
            done.signal()
        }
        let reader = Thread {
            for _ in 0..<iterations {
                let (planes, isNew) = handoff.publish()
                if isNew, !isUniform(planes) { torn.bump() }
            }
            done.signal()
        }
        writer.start()
        reader.start()
        done.wait()
        done.wait()

        XCTAssertEqual(torn.value, 0, "a torn frame reached the encoder")
    }

    // MARK: Publishing

    func testNothingIsPublishedBeforeAnythingIsWritten() {
        let handoff = FrameHandoff(width: 64, height: 64)
        XCTAssertFalse(handoff.publish().isNew)
        XCTAssertFalse(handoff.hasFrame)
    }

    func testAWrittenFrameIsPublishedExactlyOnce() {
        let handoff = FrameHandoff(width: 64, height: 64)
        handoff.write { planes in
            fill(planes, with: 42)
            return true
        }
        let first = handoff.publish()
        XCTAssertTrue(first.isNew)
        XCTAssertEqual(first.planes.y.first, 42)
        XCTAssertTrue(handoff.hasFrame)

        // Nothing new since, but the planes still come back — a keyframe
        // owed on a still screen must be answered from the last picture.
        let second = handoff.publish()
        XCTAssertFalse(second.isNew)
        XCTAssertEqual(second.planes.y.first, 42)
    }

    /// Latest-wins: two frames converted before the encoder gets to either
    /// must yield the newer one.
    func testAnUnpublishedFrameIsOverwrittenByANewerOne() {
        let handoff = FrameHandoff(width: 64, height: 64)
        handoff.write { planes in
            fill(planes, with: 1)
            return true
        }
        handoff.write { planes in
            fill(planes, with: 2)
            return true
        }
        let published = handoff.publish()
        XCTAssertTrue(published.isNew)
        XCTAssertEqual(published.planes.y.first, 2)
    }

    /// A conversion that failed must not be published — the buffer still
    /// holds whatever it had before (the previous frame, or the initial grey).
    func testAFailedConversionIsNotPublished() {
        let handoff = FrameHandoff(width: 64, height: 64)
        handoff.write { _ in false }
        XCTAssertFalse(handoff.publish().isNew)
        XCTAssertFalse(handoff.hasFrame)
    }

    /// The two buffers must genuinely alternate, or `publish` handing back
    /// the buffer the writer keeps filling is the torn-frame bug again.
    func testPublishingAlternatesBetweenTwoDistinctBuffers() {
        let handoff = FrameHandoff(width: 64, height: 64)
        var seen: [ObjectIdentifier] = []
        for value in UInt8(1)...UInt8(4) {
            handoff.write { planes in
                fill(planes, with: value)
                return true
            }
            let published = handoff.publish()
            XCTAssertEqual(published.planes.y.first, value)
            seen.append(ObjectIdentifier(published.planes))
        }
        XCTAssertEqual(Set(seen).count, 2, "expected exactly two buffers in rotation")
    }

    // MARK: Resize

    /// A resize must re-make both buffers, or the encoder reads planes sized
    /// for the previous resolution on its next pass.
    func testResizeReplacesBothBuffersAndDropsWhatWasInThem() {
        let handoff = FrameHandoff(width: 64, height: 64)
        handoff.write { planes in
            fill(planes, with: 7)
            return true
        }
        XCTAssertTrue(handoff.publish().isNew)

        handoff.resize(width: 32, height: 32)
        XCTAssertEqual(handoff.width, 32)
        XCTAssertEqual(handoff.height, 32)
        XCTAssertFalse(handoff.hasFrame, "a resize must not leave the old frame publishable")

        let afterResize = handoff.publish()
        XCTAssertFalse(afterResize.isNew)
        XCTAssertEqual(
            afterResize.planes.y.count, 32 * 32,
            "the published planes must be sized for the NEW geometry")
    }

    func testBuffersAreSizedForTheirGeometry() {
        let handoff = FrameHandoff(width: 1920, height: 1080)
        let planes = handoff.publish().planes
        XCTAssertEqual(planes.y.count, 1920 * 1080)
        XCTAssertEqual(planes.u.count, 960 * 540)
        XCTAssertEqual(planes.v.count, 960 * 540)
    }
}

/// Fill every plane with one byte, so a torn frame (two different values) is
/// detectable. File scope, not a method, so it doesn't capture the
/// non-Sendable `XCTestCase` across real `Thread`s.
private func fill(_ planes: FrameHandoff.Planes, with value: UInt8) {
    for index in planes.y.indices { planes.y[index] = value }
    for index in planes.u.indices { planes.u[index] = value }
    for index in planes.v.indices { planes.v[index] = value }
}

private func isUniform(_ planes: FrameHandoff.Planes) -> Bool {
    guard let first = planes.y.first else { return true }
    return planes.y.allSatisfy { $0 == first }
}

/// What the reader thread saw, handed back across the thread boundary.
private final class PublishResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (isNew: Bool, uniform: Bool) = (false, true)
    func record(isNew: Bool, uniform: Bool) { lock.withLock { stored = (isNew, uniform) } }
    var isNew: Bool { lock.withLock { stored.isNew } }
    var uniform: Bool { lock.withLock { stored.uniform } }
}

/// A counter the two threads share. `@unchecked Sendable` around a lock
/// rather than an actor, so the contention being asserted on stays real.
private final class TornCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
