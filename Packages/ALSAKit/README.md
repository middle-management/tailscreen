# ALSAKit

A thin Swift wrapper over the system **ALSA** client library (libasound), for
the Linux viewer's **audio playback** and the Linux sharer's **microphone
capture** (mono, 48 kHz, Float32).

## Why a local package

The macOS viewer plays decoded audio through **AVAudioEngine** and captures the
mic through **AVAudioEngine**'s input node — an Apple-only stack in both
directions. A Linux port needs native ones, and ALSA is the lowest common
denominator on Linux: it's present on essentially every install, and **PipeWire
and PulseAudio both ship ALSA-compatibility PCM plugins**, so an ALSA reader or
writer also works on those systems (the `default` device usually routes through
them). That makes ALSA a safe portable first backend, ahead of a dedicated
PipeWire path.

So ALSAKit wraps the plain C library the same way `OpusKit` wraps libopus and
`TailscaleKit` wraps libtailscale: a SwiftPM `systemLibrary` target (`CALSA`)
plus a Foundation-only Swift wrapper (`ALSAKit`). ALSA is Linux-only, so this
package is too (unlike OpusKit, which is cross-platform).

## Prerequisite: libasound

- **Linux:** `apt install libasound2-dev` (or your distro's `alsa-lib` devel
  package)

SwiftPM finds it via pkg-config (`alsa.pc`); the `systemLibrary` target
declares the `.apt(["libasound2-dev"])` provider.

## API

Namespaced under `ALSA` (so it doesn't collide with libasound's `snd_pcm_*` C
surface):

```swift
import ALSAKit

let player = try ALSA.PCMPlayer()          // mono, 48 kHz, "default" device
let frames = try player.write(samples)     // [Float] in [-1, 1] → frames written
try player.drain()                         // block until played out
```

`ALSA.PCMPlayer` is a blocking playback stream — one per output, single-thread
(libasound's PCM handle isn't thread-safe). It takes exactly the samples the
viewer's `OpusVoiceDecoder` produces: interleaved Float32 in `[-1, 1]`, one
20 ms frame = 960 samples. It opens with the simple `snd_pcm_set_params` path
(`FLOAT_LE` interleaved, soft-resample on, 50 ms latency target). `write`
recovers from an underrun (`-EPIPE`) once and retries; the stream closes in
`deinit`. ALSA errors surface as a thrown `ALSA.Error` (`code` + `snd_strerror`
`message`).

```swift
let mic = try ALSA.PCMRecorder()           // asks for mono, 48 kHz, "default"
mic.format                                 // what the device actually gave
let samples = try mic.read(frames: mic.periodFrames)   // mono [Float] in [-1, 1]
try mic.stop()                             // drop buffered input, stay reusable
```

`ALSA.PCMRecorder` is the same thing pointing the other way, with one
deliberate asymmetry: **it negotiates instead of dictating.** The player can
name its format because a share always has 48 kHz mono to play and `default` is
a plug chain that converts anything; a capture device *has* a format and you
get it. Asking a stereo-only mic for one channel through `snd_pcm_set_params`
is an `-EINVAL` at open — the app reports "no microphone" when the truth is "a
stereo microphone". So the recorder walks the explicit `hw_params` path with
`_set_channels_near` / `_set_rate_near`, publishes what the device committed to
as `format`, and folds the channels down itself (averaging — summing two
correlated channels clips at 2× full scale, and nothing downstream reports
that; it's just heard as distortion).

Rate is *reported*, not converted: `MonoPCMConverter` in TailscreenKit already
resamples 48 kHz mono against a device rate, in a tier Linux CI tests, and a
second resampler hidden behind libasound would only ever run on non-48 kHz
machines. Period is asked for in time — 20 ms, exactly one Opus frame — over a
100 ms ring. `read` recovers from an *overrun* (also `-EPIPE`) once and retries,
mirroring `write`, and can return short, so a caller needing fixed frames should
reframe (`SystemAudioFramer`). `stop()` is `snd_pcm_drop` plus a re-prepare;
it's the counterpart of `drain()` and its opposite on purpose — trailing output
must be heard, trailing input recorded after the user stopped talking must not
be sent.

## Build & test

```bash
swift test --package-path Packages/ALSAKit   # Linux, needs libasound2-dev
```

CI's `linux-alsa` job runs exactly this. Every test opens ALSA's always-present
`"null"` PCM, which needs no sound hardware and — the part that makes a capture
gate possible at all — works in **both** directions: opened
`SND_PCM_STREAM_CAPTURE` it accepts any rate and channel count, starts, and
returns full buffers of digital silence immediately with no real-time pacing.
So open / hw-param negotiation / read / recover / teardown all run for real,
headless. The real `"default"` device is never opened in tests.

Two things `null` genuinely cannot prove, stated rather than faked:

- **Signal.** It only ever produces silence, so nothing asserts on sample
  values — a "the samples are zero" assertion would pass against a `read` that
  returned its own zero-filled scratch buffer and never called libasound. The
  channel fold's arithmetic is pinned directly on `downmixToMono` instead
  (averaging vs. summing, the dropped partial trailing frame, zero channels),
  and the live tests assert the fold's *shape*: a 960-frame read on a 2-channel
  stream must come back as 960 samples, not 1920.
- **Refusal.** `null` accepts every format asked of it, so the `_near`
  negotiation is exercised but never made to *bend*. That a stereo-only device
  reports `channels == 2` back through `format` is only verifiable on hardware.

## Status

Standalone and additive. Playback is wired into the Linux viewer through
`Packages/TailscreenLinuxBackends`; capture is not wired to anything yet — it's
the device half of the Linux mic path, whose portable half (Opus encode, RTP
packetization) already exists. See `docs/porting-plan.md` (Voice + system
audio).
