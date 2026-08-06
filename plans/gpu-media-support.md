# Spike: GPU encode, decode and render on Windows and Linux

**Why.** Mac→Windows is visibly slower than Win→Mac at the same bitrate, and the
asymmetry is in the media pipeline rather than the network. This establishes what
each platform does today, where hardware is actually reachable, and in what order
to take it — so the work is sequenced by evidence rather than by guess.

## Where we are today

Verified by reading the code, not inferred from behaviour.

| Stage | macOS (reference) | Linux / GTK | Windows / WinUI |
|---|---|---|---|
| Decode | VideoToolbox, **hardware** | libavcodec, **software** | libavcodec, **software** |
| YUV→RGB | GPU (Metal samples YUV planes) | **GPU** (GL shader in `Gtk.GLArea`) | **CPU** (`I420Converter`) |
| Present | `CAMetalLayer` | `Gtk.GLArea` | `WriteableBitmap` → WinUI `Image` |
| Encode | VideoToolbox, **hardware** | libavcodec, **software** | libavcodec, **software** |

Two things fall out of that table immediately.

**Linux already does the GPU part of rendering; Windows is the outlier.**
`GtkVideoView` draws the `FrameStore` frame with an OpenGL YUV→RGB shader and
never touches `I420Converter`. `WinUIVideoView` runs `I420Converter.convert`
per frame on the CPU and uploads the result to a `WriteableBitmap`. At
3360×2100 that is ~7 MP of colour conversion plus a full-frame upload, per
frame, on the UI thread. This is the largest verified gap in the table and it is
Windows-only.

**Both non-mac platforms encode and decode in software, and the decoder cannot
currently do otherwise.** `FFmpegKit.VideoDecoder.init` does
`avcodec_find_decoder` + `avcodec_open2(cctx, c, nil)` — no
`AVHWDeviceContext`, no `get_format` callback, no hardware pixel formats
anywhere in the package. Hardware decode is not a configuration change; it is a
feature the wrapper does not have.

The encoder is in a better position than the decoder: `FFmpegKit` already
exposes `isEncoderAvailable(_:)` and `firstAvailableEncoder(for:preferring:)`,
whose doc comment names `h264_vaapi` and `h264_nvenc` — the mechanism was built
for hardware. But both call sites ship software-only ladders:

```swift
// WGCCaptureEncoder.swift and X11CaptureEncoder.swift, identically
public static let defaultH264Encoders = ["libx264", "libopenh264"]
public static let defaultHEVCEncoders = ["libx265"]
```

Both iterate the ladder and fall through on `avcodec_open2` failure, so adding
hardware names is additive and self-healing by construction.

## What is actually reachable, and at what cost

### Hardware encode — cheapest real win

The ladder already exists, so the change is the list plus pixel-format handling.
The costs split sharply by API:

- **NVENC (`h264_nvenc`, `hevc_nvenc`) and AMF (`h264_amf`)** accept
  **system-memory** frames (`nv12` / `yuv420p`) and upload internally. These are
  close to drop-in: prepend to the ladder, confirm the frame format we already
  produce is accepted.
- **VAAPI (`h264_vaapi`) and QSV (`h264_qsv`)** want an `AVHWFramesContext` and
  frames already on the GPU. That is real plumbing in `FFmpegKit.VideoEncoder`,
  not a list edit.

So the first increment is NVENC/AMF on Windows and NVENC on Linux; VAAPI is a
second, larger step that mostly benefits Intel/AMD Linux boxes.

### Windows GPU colour convert + present

The `WinUIVideoView` header already anticipates this and explains why it wasn't
done first:

> `Image` + `WriteableBitmap` rather than `SwapChainPanel` + D3D11 on purpose.
> It is the slow answer and the correct one … Because the hand-off is
> `FrameStore` — which is portable and already used by the GTK renderer — a
> later `SwapChainPanel` implementation replaces this file without touching the
> decoder, the session, or the transport.

That is exactly the seam we want, and the GTK renderer is the working proof of
the pattern. A `SwapChainPanel` + D3D11 surface with a YUV→RGB pixel shader
removes the CPU conversion and the bitmap upload in one change, confined to one
file. New failure mode to own: device-lost, which the current path does not have.

### Hardware decode — biggest number, biggest change

`D3D11VA` / `DXVA2` on Windows and `VAAPI` / `NVDEC` on Linux need, in
`FFmpegKit.VideoDecoder`: an `av_hwdevice_ctx_create`, a `get_format` callback
selecting the hardware pixel format, and then a choice —

- **Transfer to system memory** (`av_hwframe_transfer_data`) keeps the existing
  `DecodedVideoFrame` shape and every consumer downstream. Cheapest to build,
  and it gives back the decode cost while keeping a full-frame GPU→CPU copy.
- **Zero-copy** hands the GPU surface straight to the renderer. This is the real
  prize, and it only makes sense *after* the renderer is on the GPU — which is
  the argument for doing the Windows render work before the decode work.

Note the ordering consequence: doing hardware decode first buys less than it
looks like, because the frame would land on the GPU and then be pulled back to
the CPU for `I420Converter`.

## The step that costs nothing and should come first

**Nobody currently knows what our FFmpeg builds contain.** CI uses BtbN's
**LGPL** Windows build (chosen so linking a GPL FFmpeg doesn't impose GPL on an
MIT app — the same reason `libx264` is absent and `libopenh264` does the
encoding), and distro `libavcodec` on Linux. Whether either ships
`h264_nvenc`, `h264_amf`, `h264_qsv` or VAAPI is an open question that every
recommendation above depends on.

`FFmpegKit` already has the probe (`isEncoderAvailable`). Have the `FFmpegKit`
CI job — and its Linux counterpart — print the available H.264/HEVC encoders,
decoders and hwaccels for the build they're testing. It is a few lines, it ships
nothing, and it converts the licensing/availability question from speculation
into a line in a log we already run on both platforms.

## A caveat about measuring this

The Windows install under test runs in **UTM on Apple Silicon**. Windows-on-ARM
in a VM has no hardware video decode path, so hardware decode work will show
**no improvement there** even when it is correct. It would show up on native
Windows hardware.

The GPU colour-convert-and-present work is different: it removes CPU work and a
CPU→GPU copy, so it should help even under paravirtualised graphics. That is a
second reason to sequence the render change first — it is the one whose benefit
is measurable in the environment we actually test in.

## Recommended order

1. **Print encoder/decoder/hwaccel availability in CI**, both platforms. Free,
   unblocks every decision below.
2. **Windows: `SwapChainPanel` + D3D11 with a YUV→RGB shader.** Largest verified
   asymmetry, confined to `WinUIVideoView`, seam already designed for it,
   benefit visible in a VM, and Linux is the working reference.
3. **Hardware encode, NVENC/AMF first** (system-memory frames, additive to an
   existing ladder). Helps the Win→Mac and Linux→any directions.
4. **Hardware decode with `av_hwframe_transfer_data`**, then zero-copy once (2)
   exists.
5. **VAAPI/QSV encode** with `AVHWFramesContext`, if Linux Intel/AMD matters.

## Not investigated

- Whether Media Foundation's H.264 encoder would beat going through libavcodec
  on Windows. Probably irrelevant if NVENC/AMF are present in the build.
- 10-bit / HDR interaction. The protocol already carries BT.2020 PQ 10-bit HEVC
  behind `TAILSCREEN_ENABLE_HDR`; hardware decode profiles and shader formats
  both change for Main 10, and none of that was checked here.
- Whether the GTK GL shader path is itself optimal (texture upload strategy,
  PBOs). It is at least on the right side of the CPU/GPU line, which is what
  this spike was scoped to establish.
