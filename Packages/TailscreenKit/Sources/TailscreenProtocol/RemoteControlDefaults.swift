import Foundation

/// Persisted flag for the "Allow control requests" toggle. Plain
/// `UserDefaults` (mirrors `SystemAudioDefaults`) so `AppState`'s
/// stored-property initialiser can read it without `@AppStorage`.
///
/// Defaults **on** — control still requires an explicit per-request Grant,
/// so the toggle only controls whether viewers may *ask*. Off makes the
/// server decline `.controlRequest`s immediately and stops request
/// notifications, the escape hatch against notification spam.
public enum RemoteControlDefaults {
    public static let key = "allowControlRequests"

    public static func load(defaults: UserDefaults = .standard) -> Bool {
        guard let stored = defaults.object(forKey: key) as? Bool else {
            return true
        }
        return stored
    }

    public static func save(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key)
    }
}
