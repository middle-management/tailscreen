# Spike: GPU encode, decode and render on Windows and Linux

> Status: active. Render step done separately (`plans/gpu-rendering-plan.md`,
> status DONE — Windows now does GPU YUV→RGB + present, matching Linux).
> Encode/decode hardware acceleration (this doc's steps 3, 4, 6 below)
> **not yet implemented**: `FFmpegKit.Capabilities` can probe for hardware
> encoder/decoder names, but `FFmpegCaptureEncoderBase.defaultH264Encoders`/
> `defaultHEVCEncoders` are still software-only ladders, and
> `FFmpegKit`'s decoder still opens via plain `avcodec_find_decoder` with no
> hardware-name ladder or hwaccel context. Verify current code before relying
> on any specific step below being done.

## Why

Mac→Windows was visibly slower than Win→Mac at the same bitrate; the
asymmetry was in the media pipeline, not the network. This spike established
what each platform's encode/decode/render actually does today and in what
order to fix it, rather than guessing.

## Findings that still hold

- **Hardware encoders are already present in both shipped FFmpeg builds** —
  NVENC/AMF/QSV/VAAPI on Windows (BtbN LGPL build), NVENC/QSV/VAAPI/V4L2M2M
  on Linux (distro libavcodec). The licensing worry (LGPL excludes
  libx264/libx265) doesn't block hardware encoders — those are vendor SDKs,
  not GPL code.
- **Windows Media Foundation (`h264_mf`/`hevc_mf`) is vendor-neutral** —
  wraps whatever the OS exposes, so it's one ladder entry covering
  Intel/AMD/NVIDIA without probing the GPU. Worth trying first on Windows,
  before NVENC/AMF/QSV for cases where a vendor SDK beats the OS wrapper.
- **Hardware decode is cheaper than it first looked.** `h264_qsv`,
  `h264_cuvid`, `hevc_qsv`, `hevc_cuvid`, `h264_v4l2m2m` are standalone
  named decoders selectable by name exactly like an encoder — no
  `AVHWFramesContext`/`get_format` plumbing needed. That plumbing is only
  required for the `d3d11va`/`vaapi` hwaccel route and zero-copy, which is
  why decode moved up the recommended order instead of being step 4.
- **Fixed: HEVC on Windows failed to start.** `defaultHEVCEncoders` is
  `["libx265"]` and the Windows LGPL build ships no software HEVC encoder,
  so an explicit HEVC choice threw `encoderUnavailable`. The ladder now
  falls through to H.264 (`FFmpegCaptureEncoderBase.encoderLadder`). Real
  HEVC on Windows still needs a hardware entry (`hevc_mf`/`hevc_nvenc`/
  `hevc_amf`) — part of step 3, untested without real hardware.
- **Sequencing logic**: doing hardware decode before GPU render buys less
  than it looks like, because a hardware-decoded frame would land on the
  GPU and then be pulled back to the CPU for `I420Converter` anyway — this
  is why the render fix was sequenced first (and is now done) and
  zero-copy decode is explicitly gated on it.
- **Measurement caveat**: the Windows test rig is Windows-on-ARM in UTM,
  which has no hardware video decode path at all — hardware-decode work
  will show no improvement there even if correct; it needs native Windows
  hardware to measure. GPU render/present work is unaffected by this since
  it removes CPU work regardless of virtualization.

## Recommended order (steps 3, 4, 6 still open)

1. ~~Print encoder/decoder/hwaccel availability in CI~~ — done
   (`FFmpeg.capabilityReport()`), results above.
2. ~~Fix the HEVC encoder ladder~~ — done as an H.264 fallback (above).
3. **Hardware H.264 encode**: `h264_mf` first on Windows, then NVENC/AMF/QSV;
   NVENC/VAAPI ahead of `libx264` on Linux. NVENC/AMF/MF accept
   system-memory `nv12`/`yuv420p` frames directly — no `AVHWFramesContext`
   needed. VAAPI/QSV want GPU-resident frames — real plumbing, a bigger
   second step.
4. **Hardware decode by name** (e.g. `["h264_qsv", "h264_cuvid", "h264"]`
   ladder in `FFmpegKit`'s decoder) — no hwaccel plumbing needed.
5. ~~Windows GPU colour-convert + present~~ — done, see
   `plans/gpu-rendering-plan.md`.
6. **Zero-copy decode** (`d3d11va`/`vaapi` + `get_format`) — only pays off
   now that (5) is done.

## Not investigated

- Whether Media Foundation's encoder beats going through libavcodec's other
  Windows backends directly — probably moot if NVENC/AMF are present.
- 10-bit/HDR interaction with hardware decode profiles and shader formats
  (`plans/color-hdr-fidelity.md`'s `TAILSCREEN_ENABLE_HDR` path) — unchecked.
- Whether the GTK GL shader's texture-upload strategy (PBOs etc.) is itself
  optimal — out of scope; it's on the right side of the CPU/GPU line.
