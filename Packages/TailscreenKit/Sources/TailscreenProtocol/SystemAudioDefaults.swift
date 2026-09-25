import Foundation

/// Persisted flag for the "Share system audio when sharing starts" toggle.
/// Plain `UserDefaults` (mirrors `ViewerApprovalPreference`) so `AppState`'s
/// stored-property initialiser can read it without `@AppStorage`.
///
/// Defaults **off** — sharing your computer's audio to viewers is opt-in.
public enum SystemAudioDefaults {
    public static let key = "shareSystemAudio"

    public static func load(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    public static func save(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key)
    }
}
