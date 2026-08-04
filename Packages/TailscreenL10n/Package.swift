// swift-tools-version: 6.0
import PackageDescription

// TailscreenL10n — one string catalog, three apps.
//
// The macOS app has been localized since before Linux and Windows existed, via
// `L("…")` over `String(localized:bundle: .module)`. That mechanism is Apple
// Foundation, so `docs/porting-plan.md` recorded localization as the one piece
// of the mac UI with no portable path — and the two swift-cross-ui apps grew
// ~200 hard-coded English literals in the meantime.
//
// The catalog itself was never the mac-specific part. `.lproj` directories are
// just directories, and SwiftPM builds resource bundles on every platform it
// supports. What did not port was the *lookup*: `String(localized:)` and
// `Bundle.localizedString` both bottom out in CFBundle's localization
// negotiation, which is a different implementation on Linux and Windows than
// it is on Darwin, and none of it is verifiable from a Linux CI job.
//
// So this package keeps Apple's catalog FORMAT and file layout — translators
// hand back a `<lang>.lproj/Localizable.strings`, exactly as before — and
// replaces only the resolution: a ~200-line `.strings` parser, an explicit
// language-preference chain, and a `%@`/`%lld` substituter, all of it plain
// Swift over Foundation. One code path on all three platforms, with unit tests
// that Linux CI runs on macOS's behalf.
//
// Deliberately its OWN package rather than a TailscreenKit tier: every one of
// the four consumers (three apps + TailscreenHubUI) needs the strings, and
// TailscreenHubUI is the reason it can't live in the protocol core — it would
// have had to grow a dependency on a tier full of RTP machinery to say
// "Sign in to Tailscale". Foundation only, no other dependency, so anything
// can afford it.
let package = Package(
    name: "TailscreenL10n",
    // The development language, and therefore the key language: every key in
    // the catalog IS its English source text. This makes SwiftPM treat the
    // `.lproj` directories under Sources/TailscreenL10n/Resources as
    // localizations rather than as two folders of identically-named files.
    defaultLocalization: "en",
    platforms: [
        // Match the app's floor so Apple-platform builds see the same
        // availability window (`Synchronization.Mutex` is macOS 15+).
        .macOS("15.2")
    ],
    products: [
        .library(name: "TailscreenL10n", targets: ["TailscreenL10n"])
    ],
    targets: [
        .target(
            name: "TailscreenL10n",
            resources: [
                // `.process`, not `.copy`: only the processing rule gives
                // `.lproj` directories their localization meaning. The rule
                // flattens ordinary subdirectories, but preserves `.lproj`
                // ones — which is the whole reason the catalogs sit under a
                // `Resources/` folder here rather than beside the sources.
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "TailscreenL10nTests",
            dependencies: ["TailscreenL10n"]
        ),
    ]
)
