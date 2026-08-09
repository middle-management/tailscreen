# WASAPIKit

A thin Swift wrapper over **WASAPI** shared-mode rendering and capture, for the
**Windows viewer's audio playback** and its **microphone**.

## Why a local package

The Windows viewer reuses the whole portable stack — transport, `ViewerSession`,
the Opus decoder — and needs exactly one platform-specific thing to make sound:
somewhere for the decoded PCM to go. That is the `AudioSink` protocol in
`TailscreenViewer`, which ALSAKit fills on Linux and this fills on Windows.

Voice is the mirror image: the Opus **encoder** is already portable, so the one
platform-specific thing is somewhere for the PCM to come *from*. That is
`WASAPI.Recorder`, and it is the same four COM interfaces with
`IAudioCaptureClient` at the end instead of `IAudioRenderClient` — which is why
it shares this package and, inside it, the same translation unit.

WASAPI rather than XAudio2 or the old `waveOut` MME API: it is the API every
other one is layered on, it is what a Win32 desktop app is expected to use, and
shared mode needs no exclusive access to the endpoint. `waveOut` would have been
less code — a flat C API with no COM — but it is a compatibility shim over this
same engine and adds latency for nothing.

## No prerequisite

Unlike ALSAKit (`libasound2-dev`) or FFmpegKit (`libavcodec-dev`), there is
nothing to install. WASAPI ships with Windows and its headers are already in the
Swift toolchain's `Windows.sdk`. The package links exactly one library,
`ole32`, for the COM lifetime calls — the GUIDs need none, for the reason in
the next section.

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

It is C++ rather than C for exactly one reason: **`__uuidof`** — and it uses
**no C++ standard library at all**, which is not minimalism but a requirement:
MSVC's STL hard-asserts its compiler version, so including `<cstdlib>` against
MSVC 14.51 with the clang 19 that Swift 6.1.3 ships fails with `error STL1000:
Unexpected compiler version, expected Clang 20 or newer`. That pairing is
whatever the runner image happens to install. The shim needs allocation, release
and a copy; Win32 provides all three from `<windows.h>`. The first
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

let recorder = try WASAPI.Recorder()  // default microphone endpoint
recorder.format                       // the device's rate + channel count
let chunk = try recorder.read()       // mono, device rate, possibly empty
chunk.discontinuity                   // the endpoint dropped audio before this
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

## Capture: four more things that will bite

**Reads do not block, and an empty read is normal.** `write` blocks until the
engine has taken everything; `read` deliberately does not, because a microphone
produces samples on its own schedule and the caller — which has to bin them into
20 ms Opus frames anyway — already owns a clock. `Chunk.isEmpty` between device
periods is the ordinary answer, not the end of the stream.

**Capture packets are all-or-nothing.** `IAudioCaptureClient::ReleaseBuffer` must
acknowledge exactly the frame count `GetBuffer` reported, so there is no such
thing as consuming half a packet. The shim therefore only takes packets that fit
in the caller's buffer, leaves the rest queued, and reports
`TS_WASAPI_ERR_BUFFER_TOO_SMALL` if a packet cannot fit in an *empty* one —
otherwise a short buffer would return zero frames forever while the endpoint
overran behind it. `Recorder` sizes its own buffer from the engine buffer size
the shim reports, so it cannot reach that error.

**`AUDCLNT_BUFFERFLAGS_SILENT` does not mean the buffer is zeroed.** It means the
contents are meaningless and *the client* must supply the silence. Copying it
anyway is how a muted microphone becomes full-scale noise on every viewer's
speakers — the exact failure mode the float32 check above exists to prevent, from
a different direction.

**Mono is produced by averaging every channel**, which is *not* what the macOS
mic path does — `MicCapture` picks channel 0 explicitly, because a
voice-processing tap hands it `[mic, ref_L, ref_R]` and mixing the loopback
reference back in would fold the far end into the near end (and because
`AVAudioConverter`'s default downmix *sums*, peaking around 6.0). WASAPI
shared-mode capture has no such reference channels: it hands over the endpoint's
own mix format, where a 2-channel capture device is a 2-channel microphone and
dropping half of it would throw audio away. Averaging also cannot clip. The known
cost is that an interface reporting six channels with one live input reads about
15 dB quiet; compensating would mean inferring which channels are live from their
content, and a gain that moves with the room is worse than one that is
predictably wrong.

Two related notes. `E_ACCESSDENIED` from `Recorder()` is the ordinary Windows
microphone privacy setting, which is why it gets its own `WASAPI.Error` case
instead of a hex code the user can do nothing with. And **loopback capture** —
system audio, `AUDCLNT_STREAMFLAGS_LOOPBACK` on a *render* endpoint — is the same
shim shape with one flag and a different `EDataFlow`; it is deliberately not here,
because it is a different feature with a different consent story.

Both directions ask for the `eConsole` role, not `eCommunications`. Windows
offers the latter as a separate default specifically for calls, but asking for it
on capture alone would let one machine record from a headset mic while playing to
desktop speakers — a split the user never configured — and moving both onto it is
a change to a shipped playback path that belongs in its own commit.

## `wasapi-probe`

An executable that exists to be **linked**, not run. A SwiftPM library target is
compiled but never linked, so an undefined symbol in the shim stays invisible
until something downstream links it — which is exactly how the GUID mistake
above survived its own CI step and surfaced eleven minutes later in the app.
Building this product runs the linker against a target small enough that any
error in it is ours.

CI no longer builds it, and the linker gate did not go with it: the Windows app
links WASAPIKit itself, so `Build the app` runs the same linker over the same
shim. The dedicated step only reported it sooner, which stopped being worth two
minutes a run once the build cache put the app build under two minutes. CI never
ran this probe anyway — its Windows runners have no audio endpoint, so a
legitimate "no device" failure would be indistinguishable from a broken build.
On a real desktop it is a useful one-liner — it prints both endpoints' negotiated
mix formats, which is the input `MonoPCMConverter` has to match, and then records
for three seconds and reports the **peak amplitude**. Peak rather than a frame
count on purpose: a capture session that is running but recording nothing —
wrong endpoint, muted device, or `AUDCLNT_BUFFERFLAGS_SILENT` copied instead of
honoured — delivers a perfectly healthy stream of zeros that no frame count can
tell apart from a working microphone.

## What the tests cover, and what they cannot

`swift test` runs on Linux and macOS, which is the only place it *can* run: there
is no WASAPI on a CI machine and no null endpoint to stand in for one, so
ALSAKit's trick of opening `"null"` and proving the real wrapper runs headlessly
has no counterpart here.

So the split is the one `MonoPCMConverter` and `I420Converter` were extracted
for. The sample arithmetic and the shim's error mapping live outside
`#if os(Windows)` and are covered — the averaging downmix, the rebased-slice
indexing (`Recorder` hands the downmix a slice of a reused scratch buffer, whose
indices do not start at 0), the dropped partial frame, the nonsense channel count
that must not divide by zero, and the `E_ACCESSDENIED` recognition that turns a
blocked microphone into a sentence instead of a hex code. The COM lifetime is
left to the probe's link check.

## Not verified on hardware

Everything under `#ifdef _WIN32` has been compiled and linked but never run
against a real endpoint — the capture half has additionally never been run at
all. The package builds on Linux and macOS too — the shim is `#ifdef _WIN32` and
the Swift wrapper `#if os(Windows)`, so elsewhere it resolves to an empty module
— which keeps the manifest, the wrapper's non-Windows syntax and the pure
arithmetic checked by every job rather than only the Windows one.
