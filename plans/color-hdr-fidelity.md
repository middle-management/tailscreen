# Wide-gamut / 10-bit / HDR-aware pipeline (P3, BT.2020, HEVC Main 10)

> Status: partly shipped. Phase 1 (P3 tagging, 8-bit) is fully wired and
> **on by default**. Phases 2–3 (10-bit HEVC Main10; HDR/EDR encode) are
> implemented but dormant — capability-gated behind env flags and display
> capability, and the EDR *render* path was never finished. See "What's
> left" below.

## Problem & motivation

The pipeline was hardcoded to BT.709 primaries + 8-bit 4:2:0: wide-gamut
(Display P3) Macs clipped saturated colors to sRGB and banded on gradients;
HDR/EDR content was tone-mapped away entirely. Goal: make
capture→encode→signal→decode→render color-correct, in three independently
shippable phases (P3 tagging → 10-bit Main10 → HDR/EDR), signaling color
**in-band** via the HEVC/H.264 parameter sets so no protocol/wire change is
needed for correctness itself.

Non-goals (unchanged): Dolby Vision/dynamic HDR metadata; per-viewer color
transcoding (still encode-once/fan-out); annotation colors stay sRGB.

## Key design decisions and why

- **Color rides the SPS/VPS VUI, not a new wire message.** VideoToolbox
  already writes primaries/transfer/matrix/bit-depth into the parameter
  sets emitted on every keyframe, and the existing in-band parameter-set
  path (server caches + prepends on keyframes, viewer extracts on receipt)
  already carries them with zero protocol change. The only wire addition
  across all three phases is one new UDP control byte, `PROFILE_NO`
  (`0x09`), for the Main10-unsupported → 8-bit fallback — a deliberate
  mirror of the existing `.codecUnsupported`/CODEC_NO H.264 fallback
  pattern, not a new negotiation mechanism.
- **`ColorInfo` is a settable encoder property, not a `setup(...)`
  parameter** — adding it as a param would have pushed `VideoEncoder.setup`
  past SwiftLint's 5-parameter ceiling. Same reasoning folded
  `pixelWidth`/`pixelHeight` into one `pixelSize` on the capture side.
  `ColorInfo` never travels on the capture-helper wire or in
  `TailscreenMetadata` — it was explicitly non-load-bearing there since
  correctness rides the VUI, not the wire.
- **Display-gamut/EDR probing lives in `CaptureHelperMain`, not
  `ScreenCapture`** — the pure decision (`ColorInfo.forDisplay`, unit
  tested) is separated from the impure `CGColorSpace`/`NSScreen` probe,
  which sits next to `buildFilter` (which already resolves the selection's
  display) rather than inside `ScreenCapture`, which only sees an opaque
  `SCContentFilter`. Window/app shares fall back to the main display's
  gamut — safe, since SCStream losslessly converts SDR content into a
  requested P3 space.
- **10-bit encoder input left at VideoToolbox defaults** (no
  `imageBufferAttributes`/`PixelTransferProperties` constraint) — setting
  `ProfileLevel = HEVC_Main10` alone is what makes VT emit a Main10 SPS;
  VT converts the source pixel format internally, so the extra
  constraints the original plan proposed weren't needed for a correct
  bitstream.
- **New/risky paths gated behind env flags rather than shipped live** —
  `TAILSCREEN_ENABLE_10BIT` / `TAILSCREEN_ENABLE_HDR`, plus a wide-gamut/
  EDR-capable display check — specifically so no path CI cannot exercise
  (VideoToolbox 10-bit/EDR needs real hardware + display) goes live
  untested by default.

## What's left (real gaps, not just deferred polish)

- **EDR render path is not implemented.** The renderer derives the
  correct `CAMetalLayer.colorspace` from the decoded buffer's primaries
  (so BT.2020 is tagged, not clipped), but still uses an 8-bit BGRA
  drawable and the single-texture shader — no `wantsExtendedDynamicRangeContent`,
  no `.rgba16Float` drawable, no PQ/HLG tone-map in-shader. HDR content
  therefore renders SDR-tone-mapped by the compositor, not true EDR.
- **Decoder still outputs 32BGRA (8-bit), even for a 10-bit stream** — a
  10-bit stream decodes and truncates to 8-bit; colors are correct (the
  primaries/transfer attachments still drive the layer colorspace) but the
  extra two bits of gradient precision are lost. The 10-bit decode output
  + matching 10-bit drawable is the natural next increment, blocked on
  needing GPU/display hardware to visually verify (not CI-checkable).
- **The viewer-side automatic Main10-unsupported trigger is a stub.**
  Server-side the `force8bit` fallback latch is fully wired
  (`PROFILE_NO` round-trips, tested); the client-side trigger
  (`TailscaleScreenShareClient.sendBitDepthFallbackRequest()`) exists as
  an internal seam but nothing calls it automatically yet — the
  production decoder can't cheaply distinguish "profile unsupported" from
  "codec unsupported" pre-decode. Currently harmless since 10-bit is off
  by default, so no 8-bit-only viewer ever receives a Main10 stream; needs
  a real capability probe before enabling 10-bit broadly.
- **No stats-overlay color/depth readout** ("P3 · 10-bit · HDR") — skipped
  since it was always optional UI sugar, not correctness-bearing.
- **Bandwidth ceilings for 10-bit/HDR are unaddressed** — the adaptive
  bitrate sweep and `defaultBitsPerPixel` have no per-bit-depth ceiling
  yet, so an enabled 10-bit/HDR stream could blow the loss budget on a
  marginal link before the congestion controller reacts.

## Where it lives now

- Color/format decisions: `ColorInfo` (pure, unit-tested) — mapping to VT
  CFString keys and `CGColorSpace` names, wide-gamut/HDR-capability →
  primaries/profile selection, the Main10-unsupported fallback latch.
- Capture: `ScreenCapture.swift` (`config.colorSpaceName`, pixel format
  selection), display/EDR probing in `CaptureHelperMain.swift`.
- Encode: `VideoEncoder.swift` (`colorInfo` property, profile selection).
- Decode: `VideoDecoder.swift` (still 8-bit `32BGRA` output — see above).
- Render: `MetalViewerRenderer.swift` (`layer.colorspace` derived from
  decoded attachments; EDR drawable path not yet added).
- Fallback wire byte: `PROFILE_NO` in `RTPPacket.swift`, latch in
  `TailscaleScreenShareServer.swift`, env flag `TAILSCREEN_FORCE_8BIT`
  threaded through `CaptureHelperMain.swift`.
- Existing color fixes this built on and must not regress: the full-range
  NV12 near-black fix and the sRGB-layer red-shift fix, both now
  parameterized via `ColorInfo` rather than hardcoded.
