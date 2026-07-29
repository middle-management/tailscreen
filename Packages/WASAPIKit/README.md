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

`CWASAPI` is a C target holding the COM boilerplate:

```
IMMDeviceEnumerator → IMMDevice → IAudioClient → IAudioRenderClient
```

four interfaces and a mix-format negotiation before one sample plays. Swift can
drive COM through the vtable by hand, but doing it across the language boundary
buys nothing, so the C side exposes three functions and `WASAPIKit` wraps them
in a throwing Swift API — the same split ALSAKit uses over libasound and
X11CaptureKit over libxcb.

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

## Not verified on hardware

Everything under `#ifdef _WIN32` has been compiled but never run against a real
endpoint. The package builds on Linux and macOS too — the C file is
`#ifdef _WIN32` and the Swift wrapper `#if os(Windows)`, so elsewhere it
resolves to an empty module — which keeps the manifest and the wrapper's
non-Windows syntax checked by every job rather than only the Windows one.
