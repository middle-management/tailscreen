// swift-tools-version: 6.0
import PackageDescription

// WGCCaptureKit — screen capture for the Windows sharer, via
// Windows.Graphics.Capture.
//
// Chosen over DXGI Desktop Duplication (which was written first and deleted)
// because it is what actually matches macOS: `GraphicsCapturePicker` is
// `SCContentSharingPicker`, and a `GraphicsCaptureItem` is an
// `SCContentFilter` — a display OR a single window, chosen in system UI.
// Duplication captures a whole output and nothing else, so a sharer built on it
// could only ever answer `PickerSelection.kind == .display`, and the app's share
// flow would have been shaped around a limitation the macOS app does not have.
//
// **Raw WinRT ABI, not C++/WinRT.** cppwinrt depends on MSVC's standard
// library, and MSVC's STL hard-asserts a compiler version the Swift toolchain's
// clang does not satisfy (WASAPIKit hit this as `error STL1000`). So the shim
// calls the ABI interfaces directly. C++ is still required, for `__uuidof`.
//
// Nothing to install: WinRT, D3D11 and DXGI ship with Windows.
//
// It does NOT convert to I420 — `BGRAToI420` in TailscreenProtocol does, where
// Linux CI round-trips it against the viewer's inverse converter. The shim
// stops at BGRA and a row pitch.
let package = Package(
    name: "WGCCaptureKit",
    products: [
        .library(name: "WGCCaptureKit", targets: ["WGCCaptureKit"]),
        // See the target comment: this exists to be LINKED.
        .executable(name: "wgc-probe", targets: ["wgc-probe"]),
    ],
    targets: [
        .target(
            name: "CWGCCapture",
            path: "Sources/CWGCCapture",
            linkerSettings: [
                // RoGetActivationFactory, RoActivateInstance, RoInitialize and
                // the HSTRING functions.
                .linkedLibrary("runtimeobject", .when(platforms: [.windows])),
                // D3D11CreateDevice and CreateDirect3D11DeviceFromDXGIDevice.
                .linkedLibrary("d3d11", .when(platforms: [.windows])),
                .linkedLibrary("dxgi", .when(platforms: [.windows])),
                // IInitializeWithWindow, which the picker needs to parent
                // itself to the app's window.
                .linkedLibrary("ole32", .when(platforms: [.windows])),
                // timeBeginPeriod/timeEndPeriod: the acquire loop's Sleep is
                // useless at Windows' default 15.6 ms timer granularity.
                .linkedLibrary("winmm", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "WGCCaptureKit",
            dependencies: ["CWGCCapture"],
            path: "Sources/WGCCaptureKit"
        ),
        // A link check that doubles as a manual capture test.
        //
        // A SwiftPM library target is compiled but never LINKED, so an
        // undefined symbol stays invisible until something downstream links it
        // — exactly how WASAPIKit's GUID mistake passed its own CI step and
        // surfaced eleven minutes later in the app. This has more unresolved
        // symbols than any shim here so far (four import libraries, plus every
        // activation factory), which makes the check worth more, not less.
        //
        // Worth RUNNING on a desktop too: it shows the picker, then prints the
        // chosen target's name, size and a pixel summary — so "capture works"
        // is checkable without standing up a share.
        .executableTarget(
            name: "wgc-probe",
            dependencies: ["WGCCaptureKit"],
            path: "Sources/wgc-probe"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
