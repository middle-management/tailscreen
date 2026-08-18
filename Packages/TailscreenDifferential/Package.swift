// swift-tools-version: 6.0
import PackageDescription

// TailscreenDifferential — the Swift↔Go differential suite over the stateful
// receive pipeline.
//
// This is a separate package, not a TailscreenKit test target, for one hard
// reason: a Go c-archive carries a whole Go runtime, and two of them cannot
// be linked into one binary — their cgo export symbols (`crosscall2`,
// `_cgo_panic`, `_cgo_topofstack`) collide. SwiftPM links every test target
// of a package into a single test executable on Linux, and TailscreenKit's
// `TailscreenSharerTests` already links `libtailscale.a` — so the suite that
// links `libtailscreen.a` (the public Go SDK as a c-archive) has to live in
// a package whose test binary contains exactly one Go runtime.
//
// It depends only on the `TailscreenProtocol` product (Foundation-only, no
// TailscaleKit in the build graph) plus the `CTailscreen` systemLibrary,
// which resolves the archive through `sdk/go/libtailscreen.pc` — build
// `make libtailscreen` first, and run the suite via `make test-differential`
// so PKG_CONFIG_PATH carries `sdk/go`.
let package = Package(
    name: "TailscreenDifferential",
    platforms: [
        // Match TailscreenKit's floor (irrelevant on Linux).
        .macOS("15.2")
    ],
    dependencies: [
        .package(path: "../TailscreenKit")
    ],
    targets: [
        // The public Go SDK (sdk/go) built as a C static library — the same
        // c-archive mechanism as libtailscale.a.
        .systemLibrary(
            name: "CTailscreen",
            path: "Modules/CTailscreen",
            pkgConfig: "libtailscreen"
        ),

        // The differential suite: the shipping Swift pipeline and the Go SDK
        // driven with identical seeded, clock-injected input, asserting
        // identical output at every step. The conformance vectors pin the
        // stateless codecs on both sides; this target pins the STATEFUL
        // pipeline — reorder, depacketizers, NACK scheduling, FEC group
        // solving, RR accounting — where a fixed vector file cannot express
        // a clock-driven interleaving.
        .testTarget(
            name: "TailscreenDifferentialTests",
            dependencies: [
                .product(name: "TailscreenProtocol", package: "TailscreenKit"),
                "CTailscreen"
            ],
            path: "Tests/TailscreenDifferentialTests",
            linkerSettings: [
                .linkedLibrary("pthread", .when(platforms: [.linux]))
            ]
        )
    ]
)
