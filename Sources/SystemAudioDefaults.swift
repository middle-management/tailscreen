import Foundation

/// Persisted flag for the "Share system audio when sharing starts" toggle.
/// Plain `UserDefaults` (mirrors `ViewerApprovalDefaults`) so `AppState`'s
/// stored-property initialiser can read the saved value without going through
/// `@AppStorage`, which is `@MainActor`-bound and awkward from a property
/// default.
///
/// Defaults **off** — sharing your computer's audio to viewers is opt-in.
enum SystemAudioDefaults {
    static let key = "shareSystemAudio"

    static func load(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func save(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key)
    }
}
