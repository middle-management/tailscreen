// swift-tools-version: 6.0
import PackageDescription

// TailscreenHubUI — the hub's look, shared by every swift-cross-ui app.
//
// The macOS app has a "hub": a docked window with a thick header carrying the
// wordmark and a status subtitle, a centered content column, rounded cards, and
// a Screens list of presence-dot + hostname + IP rows that expand into a detail
// pane. The GTK viewer reproduced that in swift-cross-ui primitives, because
// swift-cross-ui is a SwiftUI *subset* — no SF Symbols, `Button` takes only a
// String, no `.buttonStyle` — so the look had to be rebuilt from `Circle`,
// `Capsule`, `RoundedRectangle` and translucent tints.
//
// Then the Windows app arrived and had none of it, and the choice was to
// rebuild that work a second time or to move it somewhere both apps can reach.
// A design system that exists twice is a design system that drifts: the two
// would agree on the day they were written and never again.
//
// So it lives here, in one place, and both apps import it.
//
// Deliberately thin on dependencies: SwiftCrossUI for the views and
// TailscreenProtocol for the handful of value types the chrome renders
// (`TailscreenMetadata` behind a screen row's sharing chip, `AnnotationTool`
// behind the toolbar). Nothing platform-specific, no transport, no decoder —
// which is also what lets Linux CI typecheck the whole thing on behalf of the
// Windows app.
let package = Package(
    name: "TailscreenHubUI",
    products: [
        .library(name: "TailscreenHubUI", targets: ["TailscreenHubUI"])
    ],
    dependencies: [
        // Pinned to the exact revision both apps pin. Its `View` protocol is
        // young and can reshape across versions; a shared UI package that
        // disagreed with its consumers about that protocol would be worse than
        // no shared package at all.
        .package(
            url: "https://github.com/stackotter/swift-cross-ui",
            revision: "199a85614e3b2346aa10736b12f969af14a1f1ea"),
        .package(path: "../TailscreenKit"),
        // The string catalog the three apps share. This package is the reason
        // it isn't a TailscreenKit tier: the chrome needs to say "Sign in to
        // Tailscale" in the user's language and needs nothing else from the
        // protocol core to do it.
        .package(path: "../TailscreenL10n"),
        // Only for `ImageFormats.Image<RGBA>`, which is the argument type of
        // SwiftCrossUI's in-memory `Image` initializer — a package cannot hand
        // over raw pixels without naming it. Pinned exactly as swift-cross-ui
        // pins it, so both resolve to one copy of the type: two versions of a
        // type that appears in a public initializer's signature would not be
        // interchangeable, and the failure reads as a nonsense type error.
        .package(
            url: "https://github.com/stackotter/swift-image-formats",
            .upToNextMinor(from: "0.5.0")),
    ],
    targets: [
        .target(
            name: "TailscreenHubUI",
            dependencies: [
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                .product(name: "TailscreenL10n", package: "TailscreenL10n"),
                .product(name: "ImageFormats", package: "swift-image-formats"),
            ]
        )
    ]
)
