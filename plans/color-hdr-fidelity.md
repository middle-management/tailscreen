# Wide-gamut / 10-bit / HDR-aware pipeline (P3, BT.2020, HEVC Main 10)
> Status: implemented in this PR.

## Problem & motivation
The whole pipeline is hardcoded to **BT.709 primaries + 8-bit 4:2:0**. On a
wide-gamut (Display P3) Mac — every modern MacBook/Studio Display — saturated
reds/greens are clipped to sRGB and banding shows on gradients. HDR content
(EDR on XDR/Pro Display) is tone-mapped away entirely. This plan makes the
capture→encode→signal→decode→render path color-correct: phase 1 gets P3 tagged
end-to-end at 8-bit; phase 2 adds 10-bit HEVC Main 10; phase 3 adds HDR/EDR.

## Goals / Non-goals
Goals:
- Capture in the source display's color space (P3 / BT.2020) at 8- or 10-bit.
- Encode HEVC **Main 10** with correct color VUI (primaries/transfer/matrix, full/limited).
- Signal color info to viewers **in-band** via the HEVC parameter sets (no protocol change).
- Decode to a 10-bit `CVPixelBuffer`; render with a 10/16-bit Metal format and the
  right `CAMetalLayer.colorspace`; opt into EDR for HDR.
- Capability negotiation + graceful fallback: H.264 stays 8-bit; old viewers keep working.

Non-goals:
- Dolby Vision / dynamic metadata (HDR10+); static HDR (PQ/HLG) only in phase 3.
- Per-viewer color transcoding (we encode once, fan out — the existing model,
  `TailscaleScreenShareServer.broadcast` `:1470-1567`).
- Changing the annotation color model (`Annotation.RGBA` stays sRGB;
  `Annotation.swift:29-37`).

## Current state (with file:line references)
- **Encoder hardcodes 709 + 8-bit NV12:**
  - `VideoEncoder.swift:148-159` — sets `ColorPrimaries`/`TransferFunction`/
    `YCbCrMatrix` all to `ITU_R_709_2`, unconditionally.
  - `VideoEncoder.swift:140-144` — profile levels `kVTProfileLevel_HEVC_Main_AutoLevel`
    / `kVTProfileLevel_H264_High_AutoLevel` (**Main**, i.e. 8-bit — 10-bit needs `Main10`).
  - `VideoEncoder.swift:117-137` — `VTCompressionSessionCreate` with
    `imageBufferAttributes: nil`; no pixel-format constraint, no depth signaling.
  - No `kVTCompressionPropertyKey_PixelTransferProperties`, no full/limited-range tag
    beyond the NV12 full-range choice at capture.
- **Capture is 8-bit full-range NV12, no colorspace set:**
  - `ScreenCapture.swift:241` — `config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`
    (`420f`, 8-bit). No `config.colorSpaceName` set at all → SCStream defaults
    (typically sRGB/709 tagging), so P3 source content is captured but under-signaled.
  - `ScreenCapture.swift:232-249` — `SCStreamConfiguration` build site (the one place
    to add `colorSpaceName` + a 10-bit `pixelFormat`).
- **Decoder forces 32BGRA 8-bit output:**
  - `VideoDecoder.swift:216-220` — `createDecompressionSession` attributes:
    `kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA`,
    `kCVPixelBufferMetalCompatibilityKey: true`. 8-bit only; a 10-bit stream is
    truncated to 8-bit here.
  - `VideoDecoder.swift:82-148` — format-description builders from parameter sets
    (`CMVideoFormatDescriptionCreateFrom{H264,HEVC}ParameterSets`), `extensions: nil`
    for HEVC (`:135`) — color info comes from the SPS VUI, which VT parses.
- **Renderer is 8-bit BGRA + sRGB layer:**
  - `MetalViewerRenderer.swift:197,215` — pipeline + layer `pixelFormat = .bgra8Unorm`.
  - `MetalViewerRenderer.swift:224` — `layer.colorspace = CGColorSpace(name: .sRGB)`.
  - `MetalViewerRenderer.swift:347-357` — `CVMetalTextureCacheCreateTextureFromImage`
    with `.bgra8Unorm`. No `wantsExtendedDynamicRangeContent`, no EDR headroom.
  - `MetalViewerRenderer.swift:342-378` `render(buffer:)` — the single texture/present path.
- **Parameter-set / codec signaling paths (the in-band carrier):**
  - Encoder emits SPS/PPS(/VPS) on every IDR: `VideoEncoder.swift:293-331,333-407`;
    helper forwards them (`CaptureHelperMain.swift:466-480`, `CaptureHelperWire.swift:110-121`),
    server caches + prepends in-band on keyframes (`TailscaleScreenShareServer.swift:1470-1485`),
    viewer extracts + installs (`TailscaleScreenShareClient.swift:509-558`, decoder
    `:33-37,47-80`). **The SPS VUI already carries color primaries/transfer/matrix +
    bit depth**, so no wire-format change is needed for color signaling — it rides the
    existing parameter-set path.
  - Codec is auto-detected from RTP payload type 96/97 (`RTPPacket.swift:83-86`,
    client `:456-467`); H.264 vs HEVC needs no negotiation.
  - HEVC fallback to H.264 already exists via `.codecUnsupported`/CODEC_NO
    (`RTPPacket.swift:46`, server `:840-865`, client `:370-385`, helper
    `TAILSCREEN_FORCE_H264` `CaptureHelperMain.swift:384-387`). This is the template
    for a "Main10-unsupported → fall back to 8-bit" negotiation.
  - Metadata channel carries `videoCodec` today (`TailscreenMetadata.swift:11-18`) —
    a place to *optionally* advertise color mode for UI, but not required for correctness.
- **Existing color awareness in comments** to preserve/extend:
  - `ScreenCapture.swift:236-241` — deliberate full-range NV12 choice + range tagging note.
  - `VideoEncoder.swift:148-153` — 709 tag added because players picked 601 and shifted reds.
  - `MetalViewerRenderer.swift:220-224` — sRGB layer tag added to stop P3-vs-sRGB red shift.
- **Tests that pin codec/parameter behavior (extend, don't break):**
  - `VideoCodecTests`, `VideoParameterSetExtractionTests` (viewer-side SPS/PPS/VPS
    extraction), `ScreenShareSyntheticFramesTests` (CI-eligible decode signal).

## Design

### Phase 1 — Correct P3 tagging end-to-end at 8-bit (low risk, high payoff)
Goal: stop clipping P3 content to sRGB without touching bit depth.
1. **Capture:** set `config.colorSpaceName` on `SCStreamConfiguration`
   (`ScreenCapture.swift:232-249`) to the source display's space. Query the display's
   color space (`CGDisplayCopyColorSpace(displayID)` / `NSScreen.colorSpace`) and pick
   `CGColorSpace.displayP3` when wide-gamut, else sRGB/709. Keep 8-bit `420f`.
2. **Encode:** make the color tags in `VideoEncoder.createSession`
   (`:148-159`) reflect the captured space. For P3-in-BT.709-container the standard
   choice is primaries = `P3_D65`, transfer = `709` (or sRGB), matrix = `709`. Add a
   `colorInfo` parameter to `VideoEncoder.setup(...)` (currently `:79-85`) so the
   helper passes through what it captured, rather than the hardcoded 709 triple.
3. **Signal:** none needed — VT writes the primaries/transfer/matrix into the SPS
   VUI; they already flow in-band via the parameter-set path and VT on the decoder
   reads them back automatically (`CMVideoFormatDescriptionCreateFromHEVCParameterSets`,
   `VideoDecoder.swift:114-148`).
4. **Render:** set `layer.colorspace` to match the stream instead of hardcoded sRGB
   (`MetalViewerRenderer.swift:224`). When the decoded buffer carries a P3 attachment,
   use `CGColorSpace.displayP3`; the compositor then maps correctly to whatever
   display the viewer is on. 8-bit BGRA is fine for P3 (banding is a 10-bit concern).

Phase 1 is mostly parameterizing three already-existing hardcodes with a captured
`ColorInfo` struct, plumbed through the capture-helper wire.

### Phase 2 — 10-bit HEVC Main 10
1. **Capture 10-bit:** switch `config.pixelFormat` to a 10-bit biplanar format
   (`kCVPixelFormatType_420YpCbCr10BiPlanarFullRange` = `x420`, or `l10r` for
   packed) when the source is wide-gamut/deep-color and the encoder path is HEVC
   (`ScreenCapture.swift:241`). Gate on codec: H.264 path stays 8-bit `420f`.
2. **Encode Main 10:** use `kVTProfileLevel_HEVC_Main10_AutoLevel`
   (replacing `Main` at `VideoEncoder.swift:141`) and constrain the session's source
   pixel format via `imageBufferAttributes`/`PixelTransferProperties` so VT accepts
   the 10-bit buffer (`VideoEncoder.swift:117-137`). Set
   `kVTCompressionPropertyKey_Depth`/bit-depth-related keys as needed. VT emits a
   Main10 SPS advertising `bit_depth_luma = 10`.
3. **Signal:** in-band again — the Main10 SPS carries bit depth + color info; the
   viewer's `CMVideoFormatDescriptionCreateFromHEVCParameterSets`
   (`VideoDecoder.swift:114-148`) builds a 10-bit format description with no code
   change. Parameter-set extraction (`TailscaleScreenShareClient.extractParameterSets`
   `:526-558`, NAL types 32/33/34) is bit-depth-agnostic and already works.
4. **Decode 10-bit:** change the decoder output attribute
   (`VideoDecoder.swift:216-220`) from `32BGRA` to a 10-bit format —
   `kCVPixelFormatType_420YpCbCr10BiPlanarFullRange` (keep YUV, let Metal sample it)
   or `kCVPixelFormatType_ARGB2101010LEPacked` (RGB, simplest for the current single-
   texture shader). Choose per what the shader consumes (see render).
5. **Render 10-bit:** switch layer + pipeline + texture to a 10-bit format
   (`MetalViewerRenderer.swift:197,215,352`): `.bgr10a2Unorm` /
   `.rgb10a2Unorm` (or sample biplanar YUV in the shader and output to a
   `.rgba16Float` drawable). The current shader samples a single `texture2d<float>`
   (`:536-541`); a packed `ARGB2101010` decode output keeps that shader nearly
   unchanged (just a 10-bit texture format). A YUV output would require a
   two-plane sampler + color-matrix in the shader — bigger change, better fidelity.
   Recommendation: **decode to packed `ARGB2101010` (RGB)** in phase 2 to keep the
   renderer diff minimal; revisit YUV-in-shader only if measured overhead matters.
6. **Negotiation/fallback:** reuse the CODEC_NO template
   (`RTPPacket.swift:46`, server `:853-865`). Add a `.profileUnsupported`
   (or overload CODEC_NO semantics) so a viewer whose HW can't decode Main 10 (older
   Intel) triggers a fallback to **8-bit HEVC Main** (not necessarily all the way to
   H.264). The server already latches `forceH264` (`:227`); add a parallel `force8bit`
   latch and pass a `TAILSCREEN_FORCE_8BIT=1` env to the helper alongside
   `TAILSCREEN_FORCE_H264` (`CaptureHelperMain.swift:384-387`,
   `HelperScreenCapture.swift:72-87`).

### Phase 3 — HDR / EDR
1. **Capture HDR:** set `config.colorSpaceName` to a BT.2020 PQ/HLG space and enable
   SCStream HDR capture (`SCStreamConfiguration` HDR options on macOS 15) at
   `ScreenCapture.swift:232-249`; keep 10-bit.
2. **Encode PQ/HLG:** transfer = `kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ`
   (or `ITU_R_2100_HLG`), primaries = `ITU_R_2020`, matrix = `ITU_R_2020`
   (`VideoEncoder.swift:148-159` parameterized via `ColorInfo`). Main10 profile.
   Optionally attach mastering-display/content-light-level SEI if VT is asked to.
3. **Signal:** in-band via SPS VUI + (optionally) SEI — still no wire change.
4. **Render EDR:** on the viewer, set
   `metalLayer.wantsExtendedDynamicRangeContent = true`, layer `colorspace` to the
   matching extended-range (`CGColorSpace` `extendedLinearDisplayP3` / a BT.2020 PQ
   space), and use a `.rgba16Float` drawable so values above 1.0 survive
   (`MetalViewerRenderer.swift:213-225,197`). The PQ/HLG→linear conversion happens in
   the shader (`:536-541`) or by handing the compositor a PQ-tagged texture. Query
   `NSScreen.maximumExtendedDynamicRangeColorComponentValue` for tone-mapping headroom;
   fall back to SDR rendering (tone-map in shader) when the viewer's display has no EDR.

### Cross-cutting: the `ColorInfo` carrier
Introduce `struct ColorInfo: Codable, Sendable { primaries, transfer, matrix, bitDepth, fullRange }`
(new `Sources/ColorInfo.swift`). Captured in the helper from the SCStream config,
passed to `VideoEncoder.setup`, and — for **UI/telemetry only** — optionally added
to the capture-helper `parameterSets` wire message
(`CaptureHelperWire.swift:110-121` already carries codec+dims; append color bytes)
and to `TailscreenMetadata.videoCodec`'s neighborhood (`TailscreenMetadata.swift:11-18`).
Correctness never depends on `ColorInfo` on the wire — it always rides the SPS VUI —
but surfacing it lets the stats overlay show "P3 · 10-bit · HDR"
(`MetalViewerRenderer.ViewerStats` `:16-48`, `ViewerStatsOverlay`).

## Implementation steps (ordered checklist)
Phase 1:
1. `Sources/ColorInfo.swift`: define `ColorInfo` + a mapping to the CFString VT keys
   and to `CGColorSpace` names; pure, unit-testable.
2. `ScreenCapture.swift:232-249`: detect display color space, set `config.colorSpaceName`;
   surface the chosen `ColorInfo` to the helper runner.
3. `VideoEncoder.swift:79-85,148-159`: add `colorInfo:` param to `setup`/`createSession`;
   set the three color keys from it instead of hardcoded 709.
4. `CaptureHelperMain.swift:377-411`: pass captured `ColorInfo` into `encoder.setup`.
5. `MetalViewerRenderer.swift:224`: derive `layer.colorspace` from the decoded
   buffer's attachments (P3 when present) instead of hardcoded sRGB.
6. Verify SPS VUI round-trips (VideoParameterSetExtraction / synthetic-frames tests).

Phase 2:
7. `ScreenCapture.swift:241`: 10-bit `pixelFormat` when wide-gamut + HEVC path.
8. `VideoEncoder.swift:117-144`: Main10 profile + 10-bit source attributes; guard
   for HW support with fallback to Main/8-bit.
9. `VideoDecoder.swift:216-220`: 10-bit output pixel format (`ARGB2101010` packed).
10. `MetalViewerRenderer.swift:197,215,352`: 10-bit layer/pipeline/texture format.
11. Fallback negotiation: `RTPPacket.swift` new control byte (or reuse CODEC_NO);
    server `force8bit` latch (`TailscaleScreenShareServer.swift:227,853-865`); helper
    `TAILSCREEN_FORCE_8BIT` (`CaptureHelperMain.swift:384-387`, `HelperScreenCapture.swift:72-87`).

Phase 3:
12. `ScreenCapture.swift`: HDR capture config (BT.2020 PQ/HLG, 10-bit).
13. `VideoEncoder.swift`: PQ/HLG transfer + 2020 primaries/matrix via `ColorInfo`.
14. `MetalViewerRenderer.swift:197,213-225`: `.rgba16Float` drawable,
    `wantsExtendedDynamicRangeContent = true`, EDR colorspace, shader tone-map/headroom.
15. Localization for any new UI labels (CLAUDE.md; `LocalizationCatalogTests`).

## Files to change / add
Change: `Sources/ScreenCapture.swift`, `Sources/VideoEncoder.swift`,
`Sources/VideoDecoder.swift`, `Sources/MetalViewerRenderer.swift`,
`Sources/CaptureHelperMain.swift`, `Sources/CaptureHelperWire.swift` (optional color
bytes), `Sources/HelperScreenCapture.swift`, `Sources/TailscaleScreenShareServer.swift`,
`Sources/TailscaleScreenShareClient.swift`, `Sources/RTPPacket.swift` (phase-2
fallback byte), `Sources/TailscreenMetadata.swift` (optional UI advertise),
`Sources/ViewerStatsOverlay.swift` (color/depth readout).
Add: `Sources/ColorInfo.swift`.
Tests: `Tests/TailscreenTests/ColorInfoTests.swift`,
extend `VideoCodecTests`, `VideoParameterSetExtractionTests`, `ScreenShareSyntheticFramesTests`.

## Testing strategy
CI-able pure-decision tests (no GPU/display/tsnet — the CLAUDE.md pattern):
- `ColorInfoTests`: `ColorInfo` ↔ VT CFString keys ↔ `CGColorSpace` name mapping;
  the "which color space for this display capability" decision (wide-gamut→P3,
  HDR-capable→2020 PQ, else sRGB) as a pure function; the profile-selection decision
  (`bitDepth==10 → Main10`, else `Main`); the phase-2 fallback latch logic
  (Main10-unsupported → 8-bit, mirroring `classifyHelperExit`/`forceH264` unit style).
- Extend `VideoParameterSetExtractionTests`: feed a synthetic Main10 HEVC SPS and
  assert VPS/SPS/PPS extraction (NAL 32/33/34) is unchanged by bit depth
  (`TailscaleScreenShareClient.extractParameterSets`).
- `RTPPacketTests`/`ScreenShareProtocolTests`: any new fallback control byte round-trips
  and old parsers ignore it.

Local-only E2E (VideoToolbox + tsnet, per CLAUDE.md — CI can't grant TCC / run a GPU):
- Extend `ScreenShareSyntheticFramesTests`: inject a **pre-encoded 10-bit Main10**
  AVCC blob through `server.broadcastForTesting` (`:1729`) +
  `injectSyntheticParameters` (`:1718`) and assert the viewer's
  `onDecodedFrameForTesting` yields a `CVPixelBuffer` with a 10-bit pixel format and a
  P3/2020 color attachment. Self-skip when VideoToolbox produces no 10-bit output
  (virtualized runners), same as the existing suite's guard.
- `ScreenShareCaptureHelperTests` (local-only, real display): assert the encoded SPS
  carries the expected primaries/transfer/bit-depth for a wide-gamut main display.
- Manual: visual check on a P3 + XDR display (no automated EDR assertion is feasible).

## Risks & pitfalls (CLAUDE.md constraints)
- **All capture stays in the helper** — `SCStreamConfiguration`/`SCContentFilter`
  changes belong in `ScreenCapture.swift` / `CaptureHelperMain.swift` only; never
  add capture to the main process (CLAUDE.md).
- **No protocol/port change required.** Color/bit-depth ride the SPS VUI through the
  existing in-band parameter-set path (`TailscaleScreenShareServer.swift:1470-1485`,
  client `:509-558`); resist adding an out-of-band color-negotiation message — port
  7447 semantics stay put. The only new wire byte is the optional phase-2
  Main10-unsupported fallback signal (parallel to CODEC_NO).
- **HW support is uneven.** 10-bit HEVC decode / EDR is absent on older Intel Macs;
  the fallback ladder (Main10 → HEVC 8-bit → H.264) must be robust — reuse the proven
  `.codecUnsupported`/`forceH264` latch pattern (`:227,853-865`) and the decoder's
  session-create-failure signal (`VideoDecoder.swift:248-256`, `onDecodeFailure`).
- **`CVPixelBuffer` is not `Sendable`** (CLAUDE.md) — the decode→render hand-off
  already respects this; a 10-bit buffer changes format, not the threading contract.
- **Don't regress the two shipped color fixes:** the full-range NV12 near-black fix
  (`ScreenCapture.swift:236-241`) and the sRGB-layer red-shift fix
  (`MetalViewerRenderer.swift:220-224`) — parameterize them via `ColorInfo`, keeping
  the correct behavior when the source *is* 709/sRGB.
- **Range signaling:** full vs limited range must stay consistent capture→encode→
  decode or near-black/near-white crush returns (the exact bug the current NV12 note
  calls out). Carry `fullRange` in `ColorInfo` and tag the VUI accordingly.
- **Bandwidth:** 10-bit HDR raises bitrate; the adaptive-bitrate sweep
  (`TailscaleScreenShareServer.swift:1369-1462`) and `defaultBitsPerPixel`
  (`VideoEncoder.swift:110-115`) may need per-depth ceilings so a 10-bit stream
  doesn't blow the loss budget on a marginal link.

## Estimated scope
**L** overall, but cleanly phased:
- Phase 1 (P3 tagging, 8-bit): **M**, ~200–300 LOC — mostly parameterizing 3 hardcodes
  + `ColorInfo` plumbing. Highest value/lowest risk; ship first.
- Phase 2 (10-bit Main10): **M–L**, ~350–450 LOC — pixel formats across capture/encode/
  decode/render + fallback negotiation.
- Phase 3 (HDR/EDR): **M**, ~200–300 LOC — capture/encode transfer-function + EDR
  render path + tone-map fallback.
Total ~800–1100 LOC across the three phases; each phase independently shippable.

## Deviations
Recorded where the implementation departed from the plan (line numbers in the
plan had drifted five PRs; symbols were followed instead).

- **Scope shipped.** Phase 1 (P3 tagging end-to-end at 8-bit) is fully wired
  and **on by default**. Phases 2–3 (10-bit HEVC Main 10; HDR/EDR encode) are
  implemented but **capability-gated behind env flags** (`TAILSCREEN_ENABLE_10BIT`
  / `TAILSCREEN_ENABLE_HDR`) and additionally gated on the display actually
  being wide-gamut / EDR-capable. They compile and are internally consistent;
  they are simply dormant by default so no un-testable-on-CI 10-bit/HDR path
  goes live untested. The EDR *render* switch (Phase 3 step 4:
  `wantsExtendedDynamicRangeContent`, `.rgba16Float` drawable, PQ shader
  tone-map) is **not** implemented — the renderer derives the correct
  `CAMetalLayer.colorspace` from the decoded buffer's primaries (so BT.2020 is
  tagged, not clipped) but still uses the 8-bit BGRA drawable + single-texture
  shader. HDR content therefore renders SDR-tone-mapped by the compositor, not
  true EDR. This is the one genuinely-half-of-a-phase area and is called out
  here rather than left as half-wired code.

- **`ColorInfo` carried as an encoder property, not a `setup(…)` parameter.**
  The plan's step "add a `colorInfo:` param to `setup`/`createSession`" would
  push both past SwiftLint's `function_parameter_count` max of 5 (post
  quality-settings, `setup` already has 5). Instead `ColorInfo` is a settable
  `VideoEncoder.colorInfo` property (identical idiom to the merged
  `encoderQuality` property) read by `setup`; `createSession` takes a private
  `SessionConfig` bundle for the same reason. `ScreenCapture.startStream`
  similarly folded `pixelWidth`/`pixelHeight` into one `pixelSize` to make room
  for `colorInfo` under the same 5-param ceiling.

- **`ColorInfo` does not travel on the capture-helper wire.** The plan floated
  *optionally* appending color bytes to the `parameterSets` wire message and to
  `TailscreenMetadata` for a stats-overlay "P3 · 10-bit · HDR" readout. Skipped
  (it was explicitly non-load-bearing — correctness rides the SPS VUI). The
  `ViewerStatsOverlay` color/depth readout was likewise not added. No wire
  schema changed except the one new UDP control byte.

- **New control byte is PROFILE_NO (`0x09`), the client trigger is a seam.**
  The Main10-unsupported → 8-bit negotiation is fully wired server-side
  (`force8bit` latch → `TAILSCREEN_FORCE_8BIT` env → helper pins `ColorInfo` to
  8-bit) and the message round-trips (`RTPPacketTests`). The *viewer-side
  automatic trigger* is deliberately left as an internal seam
  (`TailscaleScreenShareClient.sendBitDepthFallbackRequest()`): the production
  decoder can't cheaply distinguish "profile unsupported" from "codec
  unsupported" pre-decode, and since 10-bit is off by default no 8-bit-only
  viewer ever receives a Main10 stream today. The mechanism is ready for when a
  real 10-bit capability probe lands.

- **10-bit encoder input attributes left at VideoToolbox defaults.** The plan
  suggested constraining the compression session's source pixel format via
  `imageBufferAttributes` / `PixelTransferProperties`. Left `nil` (as shipped):
  setting `ProfileLevel = HEVC_Main10` is what makes VT emit a Main10 SPS, and
  VT converts the source pixel format internally, so the extra constraints
  weren't needed to produce a correct 10-bit bitstream. Noted in case a future
  measurement shows VT picking a sub-optimal conversion.

- **Decoder still outputs 32BGRA (8-bit).** Phase 2 step 4 (decode to packed
  `ARGB2101010`) was **not** done: a 10-bit stream currently decodes and
  truncates to 8-bit BGRA. Colors are correct (the primaries/transfer survive
  on the buffer attachments and drive the layer colorspace); only the extra two
  bits of gradient precision are lost. Kept 8-bit to avoid changing the
  single-texture render path (Phase 2 step 5) without the on-GPU testing CI
  can't provide. The decoder change + 10-bit drawable are the natural next
  increment once the render path can be visually verified.

- **Display-gamut / EDR probing lives in `CaptureHelperMain`, not
  `ScreenCapture`.** `ColorInfo.forDisplay(…)` is the pure decision (CI-tested);
  the impure probe (`CGColorSpaceIsWideGamutRGB(CGDisplayCopyColorSpace(id))`
  and `NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue`) sits
  in the helper next to `buildFilter`, which already resolves the selection's
  display, rather than inside `ScreenCapture` (which only sees an opaque
  `SCContentFilter`). Window/app shares fall back to the main display's gamut,
  which is safe because SCStream losslessly converts SDR content into a
  requested P3 space.
