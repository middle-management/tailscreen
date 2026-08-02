---
paths:
  - "Apps/macOS/Sources/**"
---

# Localization (macOS app)

User-facing strings are localized through SwiftPM resources. `Package.swift` sets `defaultLocalization: "en"`, and the base catalog lives at `Apps/macOS/Sources/Resources/en.lproj/Localizable.strings` (alongside the unlocalized PDF/SVG assets already under `Resources/`, both picked up by the existing `.process("Resources")`).

- **Route every user-facing string through `L(_:)`** (defined in `Apps/macOS/Sources/Localization.swift`). It calls `String(localized:bundle: .module)` — the `bundle: .module` part is essential. SwiftUI's implicit `LocalizedStringKey` lookups (`Text("…")`, `Button("…")`) and a bare `String(localized:)` both default to `Bundle.main`, which in a SwiftPM executable does **not** contain the `.lproj` resources. Those live in `Bundle.module`.
- **SwiftUI:** wrap as `Text(L("…"))`. For `Button`/`Toggle`/`Picker`/`Section`/`Label`/`.help`/`.accessibilityLabel`/`.accessibilityHint`, pass `L("…")` (a plain already-localized `String`, so no double lookup). **AppKit:** `NSMenuItem(title: L("…"))`, `alert.addButton(withTitle: L("…"))`, `content.title = L("…")`, etc.
- **Keys are the English source text** (base-language-as-key). Interpolation works: `L("Viewing \(host)")` looks up `"Viewing %@"` (Int → `%lld`). Keep keys in the catalog byte-for-byte in sync with call sites — `LocalizationCatalogTests` enforces this.
- **Don't localize** log lines (`TSLogger`/`print`), error codes (`TS-…`), key-equivalent glyphs (`⌘Q`), SF Symbol names, or brand nouns ("Tailscreen", "Tailscale").
- **To add a language:** copy `en.lproj/Localizable.strings` to `<lang>.lproj/Localizable.strings` (e.g. `sv.lproj`) under `Apps/macOS/Sources/Resources/` and translate the values only. No code changes.
