// swift-tools-version: 6.0
import PackageDescription

// WGCCaptureKit — screen capture for the Windows sharer, via
// Windows.Graphics.Capture.
//
// Chosen over DXGI Desktop Duplication (whole-output only) because
// `GraphicsCapturePicker`/`GraphicsCaptureItem` match macOS's
// `SCContentSharingPicker`/`SCContentFilter`: display OR single window.
//
// **Raw WinRT ABI, not C++/WinRT** — cppwinrt needs an MSVC STL version the
// Swift toolchain's clang doesn't satisfy (WASAPIKit hit this as `error
// STL1000`). C++ still required for `__uuidof`.
//
// Does NOT convert to I420 — `BGRAToI420` in TailscreenProtocol does that,
// where Linux CI round-trips it; shim stops at BGRA + row pitch.
let package = Package(
    name: "WGCCaptureKit",
    products: [
        .library(name: "WGCCaptureKit", targets: ["WGCCaptureKit"]),
        .executable(name: "wgc-probe", targets: ["wgc-probe"]),
    ],
    targets: [
        .target(
            name: "CWGCCapture",
            path: "Sources/CWGCCapture",
            linkerSettings: [
                // RoGetActivationFactory, RoActivateInstance, RoInitialize, HSTRING.
                .linkedLibrary("runtimeobject", .when(platforms: [.windows])),
                .linkedLibrary("d3d11", .when(platforms: [.windows])),
                .linkedLibrary("dxgi", .when(platforms: [.windows])),
                // IInitializeWithWindow, to parent the picker to the app window.
                .linkedLibrary("ole32", .when(platforms: [.windows])),
                // Default 15.6ms timer granularity makes the acquire loop's Sleep useless otherwise.
                .linkedLibrary("winmm", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "WGCCaptureKit",
            dependencies: ["CWGCCapture"],
            path: "Sources/WGCCaptureKit"
        ),
        // Link check (see WASAPIKit's probe comment) that doubles as a manual
        // capture test: shows the picker, prints the chosen target's name,
        // size and a pixel summary.
        .executableTarget(
            name: "wgc-probe",
            dependencies: ["WGCCaptureKit"],
            path: "Sources/wgc-probe"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
