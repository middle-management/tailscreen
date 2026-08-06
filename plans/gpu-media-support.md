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

## RESULTS: what the builds actually carry

`FFmpeg.capabilityReport()` ran on both platforms (5fa2254). The open question
below is now closed, and two of this document's claims were wrong.

**Windows — BtbN LGPL 7.1:**

```
h264 decoders: h264 h264_qsv h264_cuvid
h264 encoders: libopenh264 h264_nvenc h264_amf h264_qsv h264_vaapi h264_mf
hevc decoders: hevc hevc_qsv hevc_cuvid
hevc encoders: hevc_nvenc hevc_amf hevc_qsv hevc_vaapi hevc_mf
hw device types: cuda vaapi dxva2 qsv d3d11va opencl vulkan d3d12va
```

**Linux — distro libavcodec:**

```
h264 decoders: h264 h264_qsv h264_cuvid h264_v4l2m2m
h264 encoders: libx264 h264_nvenc h264_qsv h264_vaapi h264_v4l2m2m
hevc decoders: hevc hevc_qsv hevc_cuvid hevc_v4l2m2m
hevc encoders: libx265 hevc_nvenc hevc_qsv hevc_vaapi hevc_v4l2m2m
hw device types: vdpau cuda vaapi qsv drm opencl vulkan
```

### Every hardware encoder we might want is already present

NVENC, AMF, QSV and VAAPI on Windows; NVENC, QSV, VAAPI and V4L2M2M on Linux.
The licensing worry was misplaced — the LGPL build excludes `libx264`/`libx265`
but ships the hardware encoders, because those are vendor SDKs rather than GPL
code. Nothing needs a different FFmpeg build.

Windows additionally has **`h264_mf` / `hevc_mf`** — Media Foundation. This
document dismissed MF as "probably irrelevant"; it is the opposite. MF is
**vendor-neutral**: it wraps whatever the OS exposes, so one ladder entry covers
Intel, AMD and NVIDIA without probing for the GPU. It is the obvious *first*
entry on Windows, with NVENC/AMF/QSV after it for cases where the vendor SDK
beats the OS wrapper.

### CORRECTION: hardware decode is far cheaper than claimed above

The section above says hardware decode "is a feature the wrapper does not have"
and describes `av_hwdevice_ctx_create` + `get_format` plumbing. That is true
only for the **hwaccel** route (`d3d11va`, `vaapi`).

`h264_qsv`, `h264_cuvid`, `hevc_qsv`, `hevc_cuvid` and `h264_v4l2m2m` are
**standalone named decoders** — selectable with `avcodec_find_decoder_by_name`
exactly like an encoder. So a decoder-name ladder mirroring the encoder ladder
gets QSV and NVDEC for roughly the same effort as the encode change, with no
`AVHWFramesContext` anywhere. The expensive plumbing only buys `d3d11va`/`vaapi`
and zero-copy.

That reorders the recommendations: hardware decode is no longer a distant
step 4.

### A defect this uncovered: HEVC sharing from Windows cannot work

`WGCCaptureEncoder.defaultHEVCEncoders` is `["libx265"]`, and the Windows build
has **no software HEVC encoder at all** — every `hevc_*` entry is hardware. The
ladder is `for name in names where FFmpeg.isEncoderAvailable(name)`, so with
`libx265` absent the loop body never executes, `opened` stays nil, and start
fails with "none of [libx265] present in this libavcodec build".

So a Windows sharer that asks for HEVC fails to start, today, on every machine.
It is invisible because the default codec preference is `auto`. Adding the
hardware names fixes a broken feature rather than optimising a working one,
which makes it the highest-value entry on the list.

Linux is unaffected: `libx265` is present there.

### Licensing note, pre-existing

Linux's distro libavcodec carries `libx264`/`libx265`, which are GPL, and the
Linux ladder lists `libx264` first. That predates this spike and is unchanged by
it, but the capability report is the first place it has been visible — worth a
look at how the AppImage and Flatpak bundle FFmpeg before anyone assumes it is
fine.

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

Revised after the capability report; step 1 is done (5fa2254).

1. ~~Print encoder/decoder/hwaccel availability in CI.~~ **Done** — results above.
2. **Fix the HEVC ladder.** `["libx265"]` matches nothing in the Windows build,
   so HEVC sharing from Windows fails to start. Put `hevc_mf` first, then
   `hevc_nvenc` / `hevc_amf` / `hevc_qsv`, keeping `libx265` for Linux. This is a
   broken feature, not a tuning knob, and it is a two-line change to an existing
   fall-through ladder.
3. **Hardware H.264 encode**, same shape: `h264_mf` first on Windows (vendor
   neutral), then NVENC/AMF/QSV; `h264_nvenc`/`h264_vaapi` ahead of `libx264` on
   Linux. Verify the frame format we already produce is accepted — NVENC, AMF and
   MF take system-memory `nv12`/`yuv420p`, so no `AVHWFramesContext` is needed.
4. **Hardware decode by name** — a `["h264_qsv", "h264_cuvid", "h264"]`-shaped
   ladder in `FFmpegKit.VideoDecoder`, mirroring the encoder's. No hwaccel
   plumbing; this is the cheap 80% of the decode win and it moved up three
   places once the report showed those decoders exist.
5. **Windows: `SwapChainPanel` + D3D11 with a YUV→RGB shader.** Still the largest
   verified asymmetry and the only item whose benefit shows up under UTM, but it
   is a bigger change than 2–4 and now sits behind them.
6. **Zero-copy decode** (`d3d11va`/`vaapi` + `get_format`), which only pays off
   once (5) exists.

## Not investigated

- Whether Media Foundation's H.264 encoder would beat going through libavcodec
  on Windows. Probably irrelevant if NVENC/AMF are present in the build.
- 10-bit / HDR interaction. The protocol already carries BT.2020 PQ 10-bit HEVC
  behind `TAILSCREEN_ENABLE_HDR`; hardware decode profiles and shader formats
  both change for Main 10, and none of that was checked here.
- Whether the GTK GL shader path is itself optimal (texture upload strategy,
  PBOs). It is at least on the right side of the CPU/GPU line, which is what
  this spike was scoped to establish.
