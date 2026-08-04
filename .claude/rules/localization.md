---
paths:
  - "Apps/macOS/Sources/**"
  - "Apps/linux/Sources/**"
  - "Apps/windows/Sources/**"
  - "Packages/TailscreenHubUI/**"
  - "Packages/TailscreenL10n/**"
---

# Localization (all three apps)

One catalog serves macOS, Linux and Windows. It lives in
**`Packages/TailscreenL10n`** — base at
`Sources/TailscreenL10n/Resources/en.lproj/Localizable.strings`, translations in
sibling `<lang>.lproj` directories — and every app depends on that package. A
string that appears on two platforms is ONE key, translated once. See the
package README for the mechanism and for why it isn't `String(localized:)`.

- **Route every user-facing string through `L(_:)`.** `import TailscreenL10n`
  (the macOS app re-exports it via `ProtocolReexports.swift`, so mac call sites
  need no import). It returns a plain, already-localized `String`.
- **SwiftUI:** wrap as `Text(L("…"))`. For `Button`/`Toggle`/`Picker`/`Section`/
  `Label`/`.help`/`.accessibilityLabel`/`.accessibilityHint`, pass `L("…")` —
  a plain `String`, so no double lookup. **AppKit:**
  `NSMenuItem(title: L("…"))`, `alert.addButton(withTitle: L("…"))`.
  **swift-cross-ui:** its `Button`/`Toggle`/`Menu`/`TextField` take a `String`
  already, so `Button(L("…"), action:)` is the whole story.
- **Keys are the English source text** (base-language-as-key). Interpolation
  works: `L("Viewing \(host)")` looks up `"Viewing %@"`, `Int` → `%lld`,
  anything else → `%@`. Keep keys in the catalog byte-for-byte in sync with call
  sites — `LocalizationCatalogTests` enforces this across **all four** source
  trees, and it runs on Linux CI (`make test-l10n`, the `linux-l10n` leg).
- **One literal per call.** `L("a" + "b")` does not compile: the argument is a
  `LocalizationKey`, and the catalog key is the whole sentence. A long line is
  the right answer.
- **Don't localize** log lines (`TSLogger`/`print`/stderr `warning:` notes),
  CLI usage and argument errors, self-test markers (`CGTKOVERLAY_SELFTEST …`,
  `CAPTURE_BACKEND_REPORT`), error codes (`TS-…`), key-equivalent glyphs
  (`⌘Q`), toolbar glyphs (`✎`, `↶`), SF Symbol names, codec names ("HEVC",
  "H.264"), or brand nouns ("Tailscreen", "Tailscale").
- **Interpolating a caught `error` is fine** — the key takes `%@` and the value
  renders through `String(describing:)`. Wrap the *sentence*, not the error.
- **To add a language:** copy `en.lproj/Localizable.strings` to
  `<lang>.lproj/Localizable.strings` and translate the values only. No code
  changes. A key you skip falls back to English.
- **To check a translation:** `TAILSCREEN_LANG=sv` on any of the three apps.

## Pitfalls

- **A new string renders in English on Linux/Windows but works on macOS** —
  the resource bundle didn't ship. The catalog is found beside the executable
  (`TailscreenL10n_TailscreenL10n.bundle`); a missing bundle degrades silently
  to the English keys rather than failing, which is why every packaging path
  (`app-macos.yml`, `app-linux.yml`, `scripts/windows/stage-app.sh`, the
  AppImage script, the Flatpak manifest) hard-fails when it can't find it. Add
  the copy to any new packaging path you write.
- **Never reach for `Bundle.module` here.** SwiftPM's synthesized accessor
  `fatalError`s when the bundle is absent, which would turn that silent
  degradation into a crash on launch.
