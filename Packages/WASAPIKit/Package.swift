// swift-tools-version: 6.0
import PackageDescription

// WASAPIKit — audio output for the Windows viewer's `AudioSink` backend.
//
// Wrapped the way ALSAKit wraps libasound and X11CaptureKit wraps libxcb: a
// shim (`CWASAPI`) that owns the COM boilerplate — IMMDeviceEnumerator →
// IMMDevice → IAudioClient → IAudioRenderClient, shared mode, mix-format
// negotiation — plus a Foundation-only Swift wrapper. Nothing to install: WASAPI
// ships with Windows, so unlike libasound there is no apt line and no
// pkg-config; the only build inputs are SDK headers the Swift toolchain's
// Windows.sdk already carries.
//
// The shim is C++ purely for `__uuidof` — see the note at the top of
// ts_wasapi.cpp. Its interface to Swift is still a plain `extern "C"` header.
//
// Why not `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM` and let the audio engine
// resample: see `MonoPCMConverter` in TailscreenKit. Converting on our side puts
// the format adaptation somewhere Linux CI can test it, rather than on a path
// that only ever runs on a Windows machine with a non-48 kHz endpoint.
//
// Builds on every platform on purpose. The shim is `#ifdef _WIN32` and the
// Swift wrapper `#if os(Windows)`, so elsewhere this resolves to an empty
// module — which keeps the manifest and the wrapper's syntax checked by jobs
// that are not the Windows one.
let package = Package(
    name: "WASAPIKit",
    products: [
        .library(name: "WASAPIKit", targets: ["WASAPIKit"]),
        // See the target comment: this exists to be LINKED, not to be run.
        .executable(name: "wasapi-probe", targets: ["wasapi-probe"]),
    ],
    targets: [
        .target(
            name: "CWASAPI",
            path: "Sources/CWASAPI",
            linkerSettings: [
                // CoInitializeEx / CoCreateInstance / CoTaskMemFree. The GUIDs
                // need no library: `__uuidof` reads them out of the SDK
                // headers' own DECLSPEC_UUID annotations at compile time.
                .linkedLibrary("ole32", .when(platforms: [.windows]))
            ]
        ),
        .target(
            name: "WASAPIKit",
            dependencies: ["CWASAPI"],
            path: "Sources/WASAPIKit"
        ),
        // A link check, not a program.
        //
        // Building the library target compiles the shim but never links it, so
        // the first version of this package sailed through its own CI step and
        // then failed eleven minutes later in the app's link with four
        // undefined GUID symbols. An executable forces the link, which is the
        // step that actually catches a missing symbol — and it does so in
        // seconds, against a target small enough that the error can only be
        // ours.
        //
        // Deliberately not RUN in CI: a GitHub Windows runner has no audio
        // endpoint, so opening one fails legitimately and an exit code would
        // report a healthy build as broken.
        .executableTarget(
            name: "wasapi-probe",
            dependencies: ["WASAPIKit"],
            path: "Sources/wasapi-probe"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
