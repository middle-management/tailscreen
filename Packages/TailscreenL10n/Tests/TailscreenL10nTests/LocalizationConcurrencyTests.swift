import Dispatch
import Foundation
import XCTest

@testable import TailscreenL10n

/// The catalog under concurrent first-load and lookup.
///
/// `LocalizationCatalog` is a process-wide `@unchecked Sendable` singleton
/// whose table is resolved lazily on first use from whichever thread asks
/// first. This is the suite `make test-l10n`'s `--sanitize=thread` run
/// exercises — without it, this package's private `Guarded` copy would be a
/// lock no TSan job ever watches.
///
/// Assertions are interleaving-independent: every thread must see one
/// fully-resolved catalog, whichever thread won the load race.
final class LocalizationConcurrencyTests: XCTestCase {

    /// Reset on the way out rather than handing the next suite a half-raced singleton.
    override func tearDown() {
        LocalizationCatalog.shared.resetForTesting()
    }

    func testConcurrentFirstLoadAndLookupAgreeOnOneCatalog() {
        let catalog = LocalizationCatalog.shared
        // Genuinely race the lazy first load, not a warm cache.
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
        // Holds whether or not a catalog was found on disk — no fixture needed.
        XCTAssertFalse(
            translations.withLock { $0 }.first?.isEmpty ?? true,
            "the resolved string is never empty"
        )
    }

    func testConcurrentResetAndLookupNeverYieldsAnEmptyAnswer() {
        let catalog = LocalizationCatalog.shared
        let empties = Guarded(0)
        let key: LocalizationKey = "Sign in to Tailscale"

        // One thread repeatedly drops the cache while others read, re-entering the lazy load.
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
