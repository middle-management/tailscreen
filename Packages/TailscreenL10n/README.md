# TailscreenL10n

One string catalog, three apps.

`L("Start Sharing")` resolves through this package on macOS, Linux and Windows
alike, against the same `Localizable.strings` files. Translating a string once
translates it everywhere it appears.

```
Sources/TailscreenL10n/
  Localization.swift        L(_:) and LocalizationKey — the API
  LocalizationCatalog.swift finding the catalog, choosing a language, caching
  LocalizationFormat.swift  %@ / %lld substitution and specifier normalization
  StringsFile.swift         the .strings parser
  Resources/
    en.lproj/Localizable.strings   base — keys are the values
    sv.lproj/Localizable.strings   Swedish
```

## Using it

```swift
import TailscreenL10n

Text(L("Stop sharing"))
Button(L("Ask to Share"), action: ask)
statusLine = L("Sharing to \(viewers.count)")   // key: "Sharing to %lld"
```

The macOS app re-exports this module from `Sources/ProtocolReexports.swift`, so
its call sites need no `import`.

Every rule about *which* strings go through `L(_:)` — and the SwiftUI / AppKit /
swift-cross-ui call-site conventions — lives in `.claude/rules/localization.md`.

## Adding a language

Copy `en.lproj/Localizable.strings` to `<lang>.lproj/Localizable.strings` under
`Sources/TailscreenL10n/Resources/`, translate the values, leave the keys
byte-for-byte alone. No code changes: the language is discovered from the
directory listing at runtime.

A key you don't translate falls back to the key, which is the English text, so a
partial translation is a working app. `LocalizationCatalogTests` enforces the
inverse — a translation may not carry keys the base catalog has dropped, and it
may not disagree with the base about how many values a sentence takes.

Check your work without changing your system language:

```bash
TAILSCREEN_LANG=sv ./tailscreen
```

## Why this isn't `String(localized:bundle:)`

That is Apple Foundation, and it was the reason `docs/porting-plan.md` listed
localization as the one piece of the mac UI with no portable path. Both it and
`Bundle.localizedString` bottom out in CFBundle's localization negotiation,
which is a different implementation off Darwin and unverifiable from a Linux CI
job.

The catalog format was never the mac-specific part — `.lproj` directories are
just directories, and SwiftPM builds resource bundles on every platform. So this
package keeps Apple's format and file layout and replaces only the resolution:
a `.strings` parser, an explicit language-preference chain, and a substituter,
all plain Swift over Foundation. One code path everywhere, with unit tests Linux
CI runs on macOS's behalf (`make test-l10n`, CI's `linux-l10n` leg).

Three consequences worth knowing:

- **The catalog is located by hand, not through `Bundle.module`.** SwiftPM's
  synthesized accessor calls `fatalError` when the resource bundle isn't beside
  the executable. That is survivable for an app whose icons live there and not
  for a lookup every label goes through: a tarball or MSIX that shipped without
  the bundle would abort on launch instead of rendering in English. Not finding
  the catalog is an ordinary outcome here — the table stays empty and every key
  resolves to itself. The packaging scripts assert the bundle's presence
  precisely *because* its absence is silent at runtime.
- **Substitution is hand-written, not `String(format:)`.** A translation has to
  be able to reorder values (`%1$@`, `%2$lld`) — for several languages that's the
  only grammatical option — and positional support off Darwin is thin. And
  because the argument list is the authority rather than the format string, a
  translator who types `%d` where the key says `%@` gets an oddly rendered word
  rather than a garbage pointer read.
- **Lookup has a specifier-normalized fallback index.** `%@ watching` finds
  `%lld watching`. Call-site keys are built from Swift types, catalogs are
  written by hand, and the two drifting apart shouldn't silently untranslate a
  string. It's the same normalization the catalog test matches with, so the test
  can't pass on a correspondence the app doesn't make.

## Environment

| Variable | Effect |
|---|---|
| `TAILSCREEN_LANG` | Force a language (`sv`, `en-GB`, or a comma-separated preference list), whatever the system says. |
| `TAILSCREEN_L10N_BUNDLE` | Point the lookup at a directory of `.lproj`s, or at a `…_TailscreenL10n.bundle`. For tests and unusual packaging layouts. Authoritative — when set, nowhere else is searched, so naming a directory that has no catalog gives you English rather than one found elsewhere. |

Otherwise the preference order is `Locale.preferredLanguages` on Apple
platforms, and `LC_ALL` / `LC_MESSAGES` / `LANG` (falling back to
`Locale.current`) elsewhere.
