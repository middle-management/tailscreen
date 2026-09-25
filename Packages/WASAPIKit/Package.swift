// swift-tools-version: 6.0
import PackageDescription

// WASAPIKit — audio output (viewer `AudioSink`) and mic input, via a COM shim
// (`CWASAPI`: IMMDeviceEnumerator → IMMDevice → IAudioClient →
// IAudioRenderClient, shared mode) plus a Foundation-only Swift wrapper.
// Nothing to install — WASAPI ships with Windows.
//
// Shim is C++ only for `__uuidof` (see ts_wasapi.cpp); interface to Swift is
// plain `extern "C"`. Resampling stays out of the shim — see `MonoPCMConverter`
// in TailscreenKit, so Linux CI can test the format adaptation.
//
// Builds on every platform: shim is `#ifdef _WIN32`, wrapper `#if
// os(Windows)`, so non-Windows jobs still typecheck the manifest.
let package = Package(
    name: "WASAPIKit",
    products: [
        .library(name: "WASAPIKit", targets: ["WASAPIKit"]),
        .executable(name: "wasapi-probe", targets: ["wasapi-probe"]),
    ],
    targets: [
        .target(
            name: "CWASAPI",
            path: "Sources/CWASAPI",
            linkerSettings: [
                // CoInitializeEx / CoCreateInstance / CoTaskMemFree.
                .linkedLibrary("ole32", .when(platforms: [.windows]))
            ]
        ),
        .target(
            name: "WASAPIKit",
            dependencies: ["CWASAPI"],
            path: "Sources/WASAPIKit"
        ),
        // A link check, not a program: a library target compiles the shim but
        // never links it, so a missing GUID symbol stays invisible until the
        // app links it. Not run in CI — no audio endpoint on Windows runners.
        .executableTarget(
            name: "wasapi-probe",
            dependencies: ["WASAPIKit"],
            path: "Sources/wasapi-probe"
        ),
        // Runs on Linux/macOS (the only place it can): mono downmix + the
        // shim's error mapping; COM lifetime is left to the probe's link check.
        .testTarget(
            name: "WASAPIKitTests",
            dependencies: ["WASAPIKit"],
            path: "Tests/WASAPIKitTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
