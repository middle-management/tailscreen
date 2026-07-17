# OpusKit

A thin, cross-platform Swift wrapper over the system **libopus**, for
Tailscreen's Opus-only audio path (mono, 48 kHz).

## Why a local package, not a SwiftPM dependency

The Opus packages on the SwiftPM index (`alta/swift-opus`, etc.) are
Apple-only and bind to AVFoundation types (`AVAudioPCMBuffer` /
`AVAudioEngine`) — exactly the platform coupling the Opus-only audio
decision (see `docs/porting-plan.md` #6) exists to remove. Several are also
minimally maintained. So OpusKit wraps the plain C library the same way
`TailscaleKitPackage` wraps libtailscale: a SwiftPM `systemLibrary` target
(`COpus`) plus a Foundation-only Swift wrapper (`OpusKit`). The same source
builds on macOS, Linux, and Windows against a system libopus.

## Prerequisite: libopus

- **Linux:** `apt install libopus-dev` (or your distro's `opus`/`opusdev`)
- **macOS:** `brew install opus`
- **Windows:** `vcpkg install opus`

SwiftPM finds it via pkg-config (`opus.pc`); the `systemLibrary` target
declares `.apt(["libopus-dev"])` / `.brew(["opus"])` providers.

## API

Namespaced under `Opus` (so it doesn't collide with libopus's own opaque
`OpusEncoder` / `OpusDecoder` C types):

```swift
import OpusKit

let encoder = try Opus.Encoder()          // mono, 48 kHz, VOIP application
try encoder.setBitrate(24_000)
let packet = try encoder.encode(pcm)      // [Int16] → Data (one 20 ms frame)

let decoder = try Opus.Decoder()
let out = try decoder.decode(packet)      // Data → [Int16]
let concealed = try decoder.decode(nil, frameSize: .ms20)  // packet-loss concealment
```

Encoder and decoder are stateful (inter-frame prediction, PLC history) — one
instance per stream, single-threaded.

## Build & test

```bash
swift test --package-path OpusKitPackage   # macOS or Linux, needs libopus
```

CI's `linux-opus` job runs exactly this. The tests are encode→decode round
trips (structural + rough-energy assertions — Opus is lossy, never
byte-exact), a multi-frame stream, packet-loss concealment, and
invalid-frame rejection.

## Status

Integrated. The app links OpusKit and uses it for the whole audio path:
`Sources/OpusAudioCodec.swift` wraps it as `OpusVoiceEncoder` /
`OpusVoiceDecoder` (the Float32↔Int16 boundary + 960-sample / 20 ms
framing), which `VoiceChannel` (voice) and `SystemAudioTap` (system audio,
`.audio` mode) drive. Opus fully replaced the AudioToolbox AAC-LC path; the
RTP payload types (98 voice / 99 system) are unchanged on the wire.
