// swift-tools-version: 6.0
import PackageDescription

// TailscreenHubUI — the hub's look, shared by every swift-cross-ui app.
//
// The macOS app's "hub" (docked window, header, cards, Screens list) was
// rebuilt in swift-cross-ui primitives for the GTK viewer, since swift-cross-ui
// is a SwiftUI subset with no SF Symbols or `.buttonStyle`. Rather than
// rebuild it again for Windows, it lives here, in one place both apps import,
// so the design system can't drift between them.
//
// Deliberately thin on dependencies: SwiftCrossUI for the views and
// TailscreenProtocol for the handful of value types the chrome renders
// (`TailscreenMetadata`, `AnnotationTool`). Nothing platform-specific, no
// transport, no decoder — which is also what lets Linux CI typecheck the
// whole thing on behalf of the Windows app.
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
