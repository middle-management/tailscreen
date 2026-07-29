// swift-tools-version: 6.0
import PackageDescription

// DXGICaptureKit — screen capture for the Windows sharer's `CaptureEncoding`
// backend. The counterpart of X11CaptureKit on Linux.
//
// Same shape as WASAPIKit, and the same two hard-won constraints: the shim is
// C++ solely for `__uuidof` (so the COM GUIDs come from the SDK headers rather
// than being typed out, where a mistake would be an E_NOINTERFACE at run time
// that no CI job can catch), and it includes no C++ standard library header,
// because MSVC's STL hard-asserts a compiler version the Swift toolchain's
// clang does not satisfy.
//
// Nothing to install: D3D11 and DXGI ship with Windows and their headers are in
// the toolchain's Windows.sdk.
//
// Unlike X11CaptureKit this does NOT convert to I420 — `BGRAToI420` in
// TailscreenProtocol does, where Linux CI round-trips it against the viewer's
// inverse. The shim's job stops at handing over BGRA and a row pitch.
//
// Builds on every platform: the shim is `#ifdef _WIN32` and the Swift wrapper
// `#if os(Windows)`, so elsewhere it resolves to an empty module and every job
// still checks the manifest and the wrapper's syntax.
let package = Package(
    name: "DXGICaptureKit",
    products: [
        .library(name: "DXGICaptureKit", targets: ["DXGICaptureKit"]),
        // See the target comment: this exists to be LINKED, not shipped.
        .executable(name: "dxgi-probe", targets: ["dxgi-probe"]),
    ],
    targets: [
        .target(
            name: "CDXGICapture",
            path: "Sources/CDXGICapture",
            linkerSettings: [
                .linkedLibrary("d3d11", .when(platforms: [.windows])),
                .linkedLibrary("dxgi", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "DXGICaptureKit",
            dependencies: ["CDXGICapture"],
            path: "Sources/DXGICaptureKit"
        ),
        // A link check that doubles as a manual capture test.
        //
        // A SwiftPM library target is compiled but never linked, so an
        // undefined symbol in the shim stays invisible until something
        // downstream links it — which is exactly how WASAPIKit's GUID mistake
        // survived its own CI step and surfaced eleven minutes later in the
        // app. An executable makes the linker run against a target small
        // enough that any error in it is ours.
        //
        // Unlike wasapi-probe this one is worth RUNNING on a desktop: it prints
        // the captured geometry and a cheap pixel summary, which is the only
        // way to see whether Duplication is producing real content short of
        // running a whole share.
        .executableTarget(
            name: "dxgi-probe",
            dependencies: ["DXGICaptureKit"],
            path: "Sources/dxgi-probe"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
