import Dispatch
import Foundation
import XCTest

@testable import TailscreenL10n

/// The catalog under concurrent first-load and lookup.
///
/// `LocalizationCatalog` is a process-wide `@unchecked Sendable` singleton
/// read from every thread that renders a label, and its table is resolved
/// **lazily on first use** — file I/O, environment reads and all — from
/// whichever thread happens to ask first. That is the shape of thing a
/// sanitiser exists to check, and until this suite existed nothing in the
/// package touched it from two threads at once, so the gate had no execution
/// to observe: the lock's correctness was asserted by its own doc comment and
/// by nothing else.
///
/// It is also why `make test-l10n` runs this package twice, the second time
/// under `--sanitize=thread`. The package has no dependencies, so the
/// sanitised run costs nothing but a rebuild, and without it this package's
/// private copy of `Guarded` — see `Guarded.swift` here, and the repo-wide
/// argument on `TailscreenProtocol.Guarded` — would be the one lock in the
/// repo that no TSan job ever looks at.
///
/// The assertions are interleaving-independent: every thread must observe the
/// same fully-resolved catalog, whichever of them lost the race to populate
/// it. A torn read — a table half-published, or a language read from a state
/// another thread was still building — shows up as a disagreeing answer.
final class LocalizationConcurrencyTests: XCTestCase {

    /// Leave the shared catalog the way `LocalizationLookupTests` leaves it.
    /// That suite's header explains why its env-mutating cases share one
    /// class; this one mutates no environment, but it does drop the cache,
    /// so it resets on the way out rather than handing the next suite a
    /// half-raced singleton.
    override func tearDown() {
        LocalizationCatalog.shared.resetForTesting()
    }

    func testConcurrentFirstLoadAndLookupAgreeOnOneCatalog() {
        let catalog = LocalizationCatalog.shared
        // Drop any table a previous suite resolved, so this run genuinely
        // races the lazy first load rather than reading a warm cache.
        catalog.resetForTesting()

        let key: LocalizationKey = "Sign in to Tailscale"
        let languages = Guarded<Set<String>>([])
        let translations = Guarded<Set<String>>([])

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<250 {
                let language = catalog.activeLanguage
                let text = catalog.string(for: key)
                languages.withLock { $0.insert(language) }
                translations.withLock { $0.insert(text) }
            }
        }

        XCTAssertEqual(
            languages.withLock { $0 }.count, 1,
            "every thread must see one resolved language, whoever won the first-load race"
        )
        XCTAssertEqual(
            translations.withLock { $0 }.count, 1,
            "one key must resolve to one string, never to a half-published table"
        )
        // A key absent from the table falls back to itself, which IS the
        // English text — so this holds whether or not a catalog was found on
        // disk, and the suite needs no fixture to be meaningful.
        XCTAssertFalse(
            translations.withLock { $0 }.first?.isEmpty ?? true,
            "the resolved string is never empty"
        )
    }

    func testConcurrentResetAndLookupNeverYieldsAnEmptyAnswer() {
        let catalog = LocalizationCatalog.shared
        let empties = Guarded(0)
        let key: LocalizationKey = "Sign in to Tailscale"

        // One thread repeatedly drops the cache while the others read through
        // it, so the lazy load is re-entered many times rather than once.
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for _ in 0..<200 {
                if worker == 0 {
                    catalog.resetForTesting()
                } else if catalog.string(for: key).isEmpty {
                    empties.withLock { $0 += 1 }
                }
            }
        }

        XCTAssertEqual(
            empties.withLock { $0 }, 0,
            "a lookup racing a reset must still resolve, never return the empty string"
        )
    }
}
