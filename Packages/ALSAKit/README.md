# ALSAKit

A thin Swift wrapper over the system **ALSA** client library (libasound), for
the **Linux viewer's audio playback** (mono, 48 kHz, Float32).

## Why a local package

The macOS viewer plays decoded audio through **AVAudioEngine** — an Apple-only
stack. A Linux port needs a native output sink, and ALSA is the lowest common
denominator on Linux: it's present on essentially every install, and **PipeWire
and PulseAudio both ship ALSA-compatibility PCM plugins**, so an ALSA writer
also works on those systems (the `default` device usually routes through them).
That makes ALSA a safe portable first backend, ahead of a dedicated PipeWire
path.

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

## Build & test

```bash
swift test --package-path Packages/ALSAKit   # Linux, needs libasound2-dev
```

CI's `linux-alsa` job runs exactly this. The tests open ALSA's always-present
`"null"` PCM (discards output, needs no sound hardware) so they run headless:
they write a 960-sample frame (sine / silence), a multi-frame run, and an
empty-buffer no-op, asserting frames-written and that nothing throws. The real
`"default"` device is never opened in tests.

## Status

Standalone and additive — nothing depends on it yet. It's the Linux viewer's
audio-output backend, the counterpart to the mac viewer's AVAudioEngine sink.
Wiring it into the viewer's audio path (behind `VoiceChannel`'s platform I/O)
is a later Linux-porting step; see `docs/porting-plan.md` (Voice + system
audio).
