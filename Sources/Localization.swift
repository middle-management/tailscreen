import Foundation

/// Resolve a user-facing string from the app's localization catalog.
///
/// Tailscreen ships its `.lproj` localizations as SwiftPM resources, which
/// land in `Bundle.module` — **not** `Bundle.main`. Both SwiftUI's implicit
/// `LocalizedStringKey` lookups (`Text("…")`, `Button("…")`, …) and a bare
/// `String(localized:)` default to `Bundle.main`, so they'd silently miss
/// our catalog and only ever return the development-language key. Routing
/// every user-visible string through `L(_:)` keeps the lookup pointed at the
/// bundle that actually contains the strings.
///
/// The key is the English source text itself (Apple's recommended
/// base-language-as-key convention). String interpolation is supported and
/// produces the usual format specifiers in the key, e.g.
/// `L("Viewing \(host)")` looks up `"Viewing %@"`. Adding a language is then
/// just dropping a translated `Localizable.strings` into a new `<lang>.lproj`
/// under `Sources/Resources/` — no code changes.
///
/// Use `L(_:)` for plain `String` call sites (AppKit titles, `.help`,
/// `.accessibilityLabel`, notification text) and wrap SwiftUI `Text` as
/// `Text(L("…"))`. Log lines (`TSLogger` / `print`) are intentionally left
/// untranslated.
// `L` is a deliberate, widely-used shorthand for the localization lookup
// (mirrors the conventional `NSLocalizedString` wrapper name); the
// lowerCamelCase rule is waived for this one declaration.
// swift-format-ignore: AlwaysUseLowerCamelCase
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
