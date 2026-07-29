# WASAPIKit

A thin Swift wrapper over **WASAPI** shared-mode rendering, for the **Windows
viewer's audio playback**.

## Why a local package

The Windows viewer reuses the whole portable stack — transport, `ViewerSession`,
the Opus decoder — and needs exactly one platform-specific thing to make sound:
somewhere for the decoded PCM to go. That is the `AudioSink` protocol in
`TailscreenViewer`, which ALSAKit fills on Linux and this fills on Windows.

WASAPI rather than XAudio2 or the old `waveOut` MME API: it is the API every
other one is layered on, it is what a Win32 desktop app is expected to use, and
shared mode needs no exclusive access to the endpoint. `waveOut` would have been
less code — a flat C API with no COM — but it is a compatibility shim over this
same engine and adds latency for nothing.

## No prerequisite

Unlike ALSAKit (`libasound2-dev`) or FFmpegKit (`libavcodec-dev`), there is
nothing to install. WASAPI ships with Windows and its headers are already in the
Swift toolchain's `Windows.sdk`. The package links `ole32` (COM lifetime) and
`uuid` (the CLSID/IID symbols).

## Shape

`CWASAPI` holds the COM boilerplate:

```
IMMDeviceEnumerator → IMMDevice → IAudioClient → IAudioRenderClient
```

four interfaces and a mix-format negotiation before one sample plays. Swift can
drive COM through the vtable by hand, but doing it across the language boundary
buys nothing, so the shim exposes three `extern "C"` functions and `WASAPIKit`
wraps them in a throwing Swift API — the same split ALSAKit uses over libasound
and X11CaptureKit over libxcb.

It is C++ rather than C for exactly one reason: **`__uuidof`**. The first
version was C and linked `uuid.lib` for `CLSID_MMDeviceEnumerator` and the three
interface IIDs; that library does not carry them (the MMDevice GUIDs live in
MIDL-generated `_i.c` files no SDK import library includes) and the app failed
at link with four undefined symbols. The usual C workaround is to type the GUIDs
out by hand, which trades a link error the build catches for an `E_NOINTERFACE`
at run time that nothing here can. In C++ the SDK headers annotate each
interface and coclass with `DECLSPEC_UUID`, so `__uuidof(IAudioClient)` reads
the value out of the declaration at compile time: no hardcoded bytes, no extra
library, and a wrong name is a compile error.

```swift
import WASAPIKit

let player = try WASAPI.Player()      // opens the default endpoint, starts it
player.format                         // what the device negotiated
try player.write(interleaved)         // blocks until the engine takes it all
```

## Two things that will bite

**Thread affinity.** COM apartment state is per-thread. `WASAPI.Player()`
initialises the *calling* thread's apartment, so the thread that constructs a
player must be the thread that writes to it. In the app this is guaranteed by
`ThreadedAudioSink`, which calls `play` from exactly one drain thread — which is
in turn why `WASAPIAudioSink` opens the device lazily on its first buffer rather
than in `init`.

**The mix format is the device's, not yours.** Shared mode accepts only the
format `GetMixFormat` reports, which is commonly 48 kHz stereo but is 44.1 kHz
often enough to matter and 6-channel on some machines. The viewer's PCM is
48 kHz mono, so something has to adapt.

That adaptation is **not** done here. WASAPI will do it for you
(`AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM`) and its resampler is better than a linear
one — but that puts the conversion on a code path that runs only on Windows,
only on machines whose endpoint is not 48 kHz, and that nothing in this repo can
exercise. So the shim always uses the device format verbatim and reports it
back, and `MonoPCMConverter` in `TailscreenKit` does the conversion where Linux
CI can test it. In the common 48 kHz case its resampler is bypassed entirely.

For the same reason the shim refuses a mix format that is not 32-bit float
(`TS_WASAPI_ERR_FORMAT`) instead of converting sample depth silently: writing
float samples into a 16-bit buffer emits full-scale noise, and that is not a
failure anyone should have to diagnose by ear.

## `wasapi-probe`

An executable that exists to be **linked**, not run. A SwiftPM library target is
compiled but never linked, so an undefined symbol in the shim stays invisible
until something downstream links it — which is exactly how the GUID mistake
above survived its own CI step and surfaced eleven minutes later in the app.
Building this product runs the linker against a target small enough that any
error in it is ours.

CI builds it and does not run it: its Windows runners have no audio endpoint, so
a legitimate "no device" failure would be indistinguishable from a broken build.
On a real desktop it is a useful one-liner — it prints the endpoint's negotiated
mix format, which is the input `MonoPCMConverter` has to match.

## Not verified on hardware

Everything under `#ifdef _WIN32` has been compiled and linked but never run
against a real endpoint. The package builds on Linux and macOS too — the shim is
`#ifdef _WIN32` and the Swift wrapper `#if os(Windows)`, so elsewhere it
resolves to an empty module — which keeps the manifest and the wrapper's
non-Windows syntax checked by every job rather than only the Windows one.
