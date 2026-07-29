// swift-tools-version: 6.0
import PackageDescription

// WASAPIKit — audio output for the Windows viewer's `AudioSink` backend.
//
// Wrapped the way ALSAKit wraps libasound and X11CaptureKit wraps libxcb: a C
// shim (`CWASAPI`) that owns the COM boilerplate — IMMDeviceEnumerator →
// IMMDevice → IAudioClient → IAudioRenderClient, shared mode, mix-format
// negotiation — plus a Foundation-only Swift wrapper. Nothing to install: WASAPI
// ships with Windows, so unlike libasound there is no apt line and no
// pkg-config; the only build inputs are SDK headers the Swift toolchain's
// Windows.sdk already carries.
//
// Why not `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM` and let the audio engine
// resample: see `MonoPCMConverter` in TailscreenKit. Converting on our side puts
// the format adaptation somewhere Linux CI can test it, rather than on a path
// that only ever runs on a Windows machine with a non-48 kHz endpoint.
//
// Builds on every platform on purpose. The C file is `#ifdef _WIN32` and the
// Swift wrapper `#if os(Windows)`, so elsewhere this resolves to an empty
// module — which keeps the manifest and the wrapper's syntax checked by jobs
// that are not the Windows one.
let package = Package(
    name: "WASAPIKit",
    products: [
        .library(name: "WASAPIKit", targets: ["WASAPIKit"])
    ],
    targets: [
        .target(
            name: "CWASAPI",
            path: "Sources/CWASAPI",
            linkerSettings: [
                // CoInitializeEx / CoCreateInstance / CoTaskMemFree.
                .linkedLibrary("ole32", .when(platforms: [.windows])),
                // CLSID_MMDeviceEnumerator and the IAudioClient /
                // IAudioRenderClient / IMMDeviceEnumerator IIDs. Taken from the
                // SDK rather than hardcoded here: a GUID typed out by hand
                // fails at RUN time with E_NOINTERFACE, which no CI job can
                // catch, while a missing symbol fails at LINK time with a name.
                .linkedLibrary("uuid", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "WASAPIKit",
            dependencies: ["CWASAPI"],
            path: "Sources/WASAPIKit"
        ),
    ]
)
