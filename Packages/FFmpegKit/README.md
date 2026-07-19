# FFmpegKit

A thin, cross-platform Swift wrapper over the system **FFmpeg** video decoder
(libavcodec / libavutil), for the Linux/Windows Tailscreen viewer's
video-decode path.

## Why a local package, not a SwiftPM dependency

Where the macOS app decodes H.264/HEVC with **VideoToolbox**, a portable
client needs a software/GPU decoder that exists off-Apple. `libavcodec` is the
obvious one (see `docs/porting-plan.md` — "Decode"). Rather than adopt one of
the AVFoundation-bound Swift FFmpeg wrappers on the index, FFmpegKit wraps the
plain C library the same way `OpusKit` wraps libopus and `TailscaleKit` wraps
libtailscale: a SwiftPM `systemLibrary` target (`CFFmpeg`) plus a
Foundation-only Swift wrapper (`FFmpegKit`). The same source builds on macOS,
Linux, and Windows against a system FFmpeg.

## Prerequisite: FFmpeg

- **Linux:** `apt install libavcodec-dev libavutil-dev`
- **macOS:** `brew install ffmpeg`
- **Windows:** `vcpkg install ffmpeg`

SwiftPM resolves it via pkg-config (`libavcodec.pc`, which `Requires:
libavutil`); the `systemLibrary` target declares `.apt([...])` / `.brew([...])`
providers.

## API

Namespaced under `FFmpeg`:

```swift
import FFmpegKit

let decoder = try FFmpeg.VideoDecoder(codec: .h264)   // or .hevc
// Tailscreen's wire format is AVCC (length-prefixed NALs):
for frame in try decoder.decode(avcc: accessUnit) {   // → [FFmpeg.Frame]
    // frame.width, frame.height, frame.yPlane / uPlane / vPlane (packed YUV 4:2:0)
}
let tail = try decoder.flush()                        // drain at end-of-stream
```

Parameter sets (SPS/PPS/VPS) are expected **in-band** on keyframes — exactly
how the sharer sends them — so no out-of-band extradata is needed. The decoder
emits 8-bit planar YUV 4:2:0; a renderer does YUV→RGB on the GPU (so this stays
a libavcodec-only module with no libswscale dependency).

`NALUnit.avccToAnnexB(_:nalLengthSize:)` is the standalone AVCC ⇄ Annex-B
container conversion FFmpeg needs (the shared-adapter-layer piece called out in
`docs/porting-plan.md` problem #3).

## Build & test

```bash
swift test --package-path Packages/FFmpegKit   # macOS or Linux, needs FFmpeg
```

CI's `linux-ffmpeg` job runs exactly this. The tests are the pure NAL-container
conversion (no codec needed) plus a real H.264 **encode → decode round trip**
(the test drives libavcodec's encoder directly to produce genuine bitstream,
skipping if the build lacks an H.264 encoder).

## Status

Decode foundation only. Wiring it into a portable viewer (a `ViewerSession`
receive-loop + an SDL/Vulkan renderer + PipeWire audio out) is the follow-up
work — see `docs/porting-plan.md`.
