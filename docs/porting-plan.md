---
title: Porting Plan (Linux & Windows)
nav_order: 11
permalink: /porting-plan/
---

# Porting plan: Linux & Windows

This is a working plan, not a commitment. It records what porting Tailscreen
off macOS actually involves: what carries over, what must be rebuilt per
platform, and the specific protocol/architecture problems a port surfaces —
several of which are worth fixing on macOS first, while there's only one
implementation to migrate.

**Status:** Phases 0 and 1 are done — the portable core (a real SwiftPM
dependency of the app since the flip) builds and passes smoke tests on
Linux, TailscaleKit builds and tests on Linux, and the live two-node tsnet
exchange is verified (see Phase 1 below). Phases 2+ are proposal.

## What carries over as-is

- **Transport.** `libtailscale` is Go; tsnet is fully cross-platform.
  `go build -buildmode=c-archive` works on Linux today (Windows needs a
  spike — see the effort/spike note under Phasing). Ephemeral-node identity, LocalAPI peer lookup, and
  the StableNodeID admission keying all carry over unchanged.
- **The wire protocol.** Every byte on port 7447 is pinned by
  `WireByteRegistryTests` and the round-trip suites, and the protocol was
  designed to degrade per capability (extended HELLO caps, unknown
  type-byte skip, PT auto-detect). A new client that implements only the
  base profile — HELLO, RTP depacketize, PLI — interoperates with every
  shipped macOS sharer, then earns NACK/RR/FEC incrementally by
  advertising caps.
- **The portable core (~7 k lines, 29 files + the 3-file transport tier incl. interactive auth).** RTP packetization, TCP
  framing, UDP control codecs, NACK/retransmit/FEC/RR loss recovery, the
  congestion/fairness decision functions, remote-control gate/coalescing
  policy, zoom math, tuning constants. This is `TailscreenProtocol` and it
  compiles and runs on Linux now.

## What must be rebuilt per platform

| Subsystem | macOS (today) | Linux | Windows |
|---|---|---|---|
| Capture | ScreenCaptureKit (helper subprocess) | PipeWire via `org.freedesktop.portal.ScreenCast` | Windows.Graphics.Capture (WinRT); DXGI duplication fallback |
| Picker | `SCContentSharingPicker` (helper) | The portal's own consent dialog *is* the picker | `GraphicsCapturePicker` |
| Encode | VideoToolbox H.264/HEVC | VA-API / NVENC (via FFmpeg), x264/x265 software fallback | Media Foundation HW encoders, or FFmpeg (NVENC/AMF/QSV) |
| Decode | VideoToolbox | FFmpeg (libavcodec) + VA-API hwaccel — software decode **done** (`Packages/FFmpegKit`) | Media Foundation / FFmpeg + D3D11VA |
| Render | Metal (`CAMetalLayer`) | Vulkan or OpenGL; SDL as the pragmatic first cut — **landed: `Packages/SDLKit`** (SDL2 IYUV streaming texture, YUV→RGB in the renderer) | D3D11 swapchain; SDL again viable (`Packages/SDLKit` reusable) |
| Voice + system audio | CoreAudio / AVFoundation for I/O; **Opus** (OpusKit/libopus) codec — done | **ALSA playback landed for the viewer** (`Packages/ALSAKit`, `snd_pcm` FLOAT_LE writer — also works on PipeWire/PulseAudio via their ALSA-compat PCM, so a safe portable first backend); PipeWire capture + native playback later; Opus already portable | WASAPI (loopback capture is first-class); Opus already portable || Remote-control injection | `CGEvent` + Accessibility TCC | `org.freedesktop.portal.RemoteDesktop` (consent UX ≈ TCC) | `SendInput` |
| Global hotkeys | Carbon | GlobalShortcuts portal (newer compositors only) | `RegisterHotKey` |
| Tray/menubar UI | SwiftUI `MenuBarExtra` + AppKit | StatusNotifierItem + GTK4/libadwaita (or minimal custom) | `Shell_NotifyIcon` + Win32/WinUI shim |
| Notifications | UserNotifications | `org.freedesktop.Notifications` | WinRT toasts |

Swift itself runs on both targets (Linux is mature; Windows is workable —
swift-foundation replaced the old corelibs port). The alternative of
writing non-macOS clients in Go or Rust against the pinned protocol remains
open; this plan assumes Swift so the portable core is shared, but nothing
in the protocol requires it.

## Problems a port surfaces (found while extracting Phase 0)

These are the concrete details worth knowing before committing to a sharer
port. The first two have wire-protocol implications and are cheapest to
address now, additively, while all peers are macOS.

1. **~~`InputEvent` bakes the mac key model into the wire.~~ RESOLVED
   (pre-1.0 breaking change).** The wire now carries USB HID keyboard-page
   usage IDs plus a five-bit platform-neutral modifier set
   (`KeyModifiers`: shift/control/alt/meta/capsLock) instead of
   `CGKeyCode` + raw `CGEventFlags`; buttons grew `middle`, and
   button/scroll events carry the modifier snapshot so modified clicks
   work cross-platform. macOS endpoints translate through the bijective
   `MacKeyCodeMapping` table (itself part of the portable package — a
   non-mac peer needs the same table to interoperate with mac endpoints).
   A Linux/Windows peer now only needs its own native↔HID table, which
   every platform ships.
2. **App-share pointer confinement may not be portable.** The security
   property that an application share clamps injected pointer events to
   the app's window-rect union (`RemoteControlMapping.captureRect`)
   depends on global desktop coordinates, which Wayland deliberately
   hides. The RemoteDesktop portal injects relative to the captured
   stream, which is equivalent for display/window shares but has no
   app-union concept. Decision needed: on Linux, either restrict
   remote-control grants to display/window shares, or accept
   whole-stream confinement. (Multi-app *capture* is also not a portal
   concept — `PickerSelection.kind` app/multi-app maps only to macOS and
   partially to Windows.)
3. **AVCC vs Annex-B.** The RTP payloads carry AVCC-formatted NALs with
   in-band parameter sets, matching VideoToolbox's native output. FFmpeg
   and Media Foundation speak Annex-B by default — every non-VT encoder
   and decoder adapter needs start-code ⇄ length-prefix conversion and
   extradata (SPS/PPS/VPS) extraction. Mechanical, but it must live in
   the shared adapter layer, not be reinvented per platform. **Landed for
   the viewer:** `Packages/FFmpegKit` — a `systemLibrary` wrapper over
   libavcodec — provides `NALUnit.avccToAnnexB` (the shared converter) and
   `FFmpeg.VideoDecoder` (H.264/HEVC AVCC/Annex-B → YUV frames, in-band
   parameter sets, no extradata needed), CI-gated on Linux by `linux-ffmpeg`.
   In-band SPS/PPS/VPS means no separate extradata extraction is required.
4. **Encoder rate-control semantics don't transfer.** `EncoderTuning` is
   calibrated to VideoToolbox's quality key + `DataRateLimits`; VA-API,
   NVENC, and MF each have different rate-control modes. The congestion
   controller's *contract* is portable (set-bitrate, force-keyframe,
   set-frame-interval — exactly the capture-helper command set), so define
   the encoder adapter in those terms and calibrate per backend.
5. **System-audio self-exclusion is hard on Linux.** macOS uses
   `excludesCurrentProcessAudio` so viewers' voices played by Tailscreen
   are never re-captured into the PT-99 stream (echo). Windows has
   process-exclusion loopback (Win10 21H1+). PipeWire needs explicit
   routing (capture a sink the app doesn't play into, or a filter-chain) —
   design the Linux audio graph up front or ship system audio later.
6. **~~AAC on Linux is awkward.~~ RESOLVED — switched to Opus.** fdk-aac is
   license-encumbered for distribution and FFmpeg's native AAC encoder is
   worse, so rather than negotiate a second codec we replaced AAC outright
   with **Opus** (royalty-free, software-only, portable). It lives in the
   local `OpusKit` (a `systemLibrary` wrapper over libopus, CI-gated
   on Linux by `linux-opus`) and is wired into the app via the portable
   `TailscreenAudio` tier (`OpusVoiceEncoder`/`OpusVoiceDecoder`,
   960-sample / 20 ms frames). The RTP payload types (98 voice / 99 system)
   are unchanged — pre-1.0 with no deployed AAC-only peers, so no
   negotiation was needed.
7. **~~TailscaleKit's Swift wrapper needs a portability audit.~~ RESOLVED
   — audited, patched (022), and verified live on Linux.** The fixes were
   exactly the expected small ones: `canImport(Combine)` gates with an
   `AsyncStream` fallback for the two state publishers, a Glibc shim for
   the `Darwin.`-qualified syscalls, `FoundationNetworking` imports for
   URLSession types, compiling out the Network.framework SOCKS extension,
   and having `LocalAPIClient` talk to the tsnet loopback listener
   directly (it already sent the auth headers; the SOCKS hop was
   redundant for LocalAPI). The audit also surfaced and fixed a latent
   patch-stack bug (021 carried a stale hunk that GNU patch fuzz-fitted
   into duplicate Go exports — invisible on macOS's BSD patch).
   `TailscalePeerDiscovery` / `TailscaleIPNWatcher` are now unblocked to
   join the portable set.
8. **The app-state layer is Combine/SwiftUI-shaped.** `ObservableObject`
   / `@Published` don't exist off-Apple. `PortabilityShims.swift` now
   provides non-Apple stand-ins (including a `$prop.values`-compatible
   stream) so state classes like the transport tier's can join the
   portable set unchanged — but there's still no SwiftUI/objectWillChange
   machinery: non-mac UIs observe state their own way, and heavily
   SwiftUI-bound state (`AppState`) stays mac-side.
   (`ViewerAccessPolicyStore` and the `ShareLock` advisory mutex compile
   via the shims and are in the portable set.)
9. **Localization — done.** `L(_:)` used to ride
   `String(localized:bundle:)`, which is Apple Foundation, and this item
   read "non-mac UIs need their own catalog mechanism". They didn't: the
   `.lproj` catalog format was never the mac-specific part, only the
   *lookup* was. `Packages/TailscreenL10n` keeps Apple's format and file
   layout and replaces the resolution with plain Swift over Foundation —
   a `.strings` parser, an explicit language-preference chain, `%@`/`%lld`
   substitution — so all three apps read one catalog. Linux CI checks every
   `L("…")` key in all four source trees against it.
10. **The helper-process architecture is a macOS workaround, not a
    design requirement.** `replayd`/TCC coupling is the only reason
    capture lives in a subprocess. On Linux the portal session can live
    in-process (the portal handles consent and revocation); on Windows
    likewise. Keep helper isolation as an option for crash containment,
    not a porting requirement — but then the hung-helper watchdog and
    restart budget logic need an in-process analog.
11. **Color management shrinks off-mac.** P3/HDR capture-and-tag depends
    on `CGColorSpace`/EDR probing and VT writing the SPS VUI. Linux/Windows
    Phase 1 should pin BT.709 8-bit (the wire already handles this — the
    viewer PROFILE_NO fallback and `downgradedTo8Bit` exist), with wide
    gamut revisited per-encoder later.
12. **Renderer lifetime quirks are per-platform.** The mac viewer holds
    its `NSWindow` for process lifetime to dodge a VideoToolbox/Metal
    teardown race. Vulkan/D3D swapchains have their own teardown
    orderings; budget time for the equivalent bug hunt.

## Phasing

**Phase 0 — portable core (done).** `TailscreenKit` compiles
the wire protocol + decision logic on Linux with smoke tests; the
`linux-protocol` CI job keeps it that way.

**Phase 1 — transport spike (done).** Verified on a Linux host
(Ubuntu 24.04, Swift 6.1.2, Go 1.24): `libtailscale.a` builds as a Linux
c-archive, the patched TailscaleKit wrapper compiles warning-free and
passes its unit tests (both now enforced by the `linux-tailscalekit` CI
job), and — live against a native headscale (`scripts/e2e-up-native.sh`
already runs on Linux) — two Swift tsnet nodes came up, exchanged TCP
(listener/dial/send/receive), exchanged UDP datagrams through the patched
`PacketListener` socketpair bridge (the exact transport the RTP video
path uses), and served LocalAPI status over the direct loopback path
(`backend=Running`, peer visible — peer discovery works). Notably the
WireGuard handshake that GitHub's *macOS* runner sandbox blocks completed
without issue on Linux, so promoting the live two-node exchange to a
Linux CI job is a realistic follow-up. `TailscalePeerDiscovery` /
`TailscaleIPNWatcher` are in the portable set (the
`TailscreenTransport` target, Linux-built in CI) — a non-macOS client
gets tailnet bring-up, peer discovery, and IPN-bus watching from the
same sources the mac app ships.

**Phase 2 — Linux viewer.** Headless first: dial a macOS sharer, HELLO,
depacketize, FFmpeg-decode, assert on decoded frames (the Linux twin of
`ScreenShareSyntheticFramesTests`). Then an SDL/Vulkan window, audio
playback, PLI/NACK/RR/FEC (already in the portable core), and annotations
out. (Remote-control input capture is deprioritized — see the effort note
below.) A viewer-only Linux release is a shippable milestone on its own.

*Landed:* the portable **viewer data-plane core** — `ViewerSession` in the
new `TailscreenViewer` target (`Packages/TailscreenKit`). It's host-agnostic:
given inbound RTP + a host clock it produces decoded video frames, decoded
audio, and outbound feedback bytes (HELLO/NACK/PLI/RR), reusing the existing
depacketizers + `NACKScheduler`/`RRAccounting`/`OpusVoiceDecoder`, behind
`VideoDecoding`/`VideoSink`/`AudioSink` protocols so the concrete FFmpeg
decoder / SDL renderer / ALSA sink plug in later without this target linking
them. It owns no socket/thread/timer, so it's fully unit-tested
(`TailscreenViewerTests`) and Linux-buildable today. **FEC ingest now
landed:** `FECGroupBuffer` + `FECCodec.recover` arm on the first `0x0D`
parity datagram (not bare negotiation — a clean link that never sees parity
keeps phase-1 NACK timing and pays no buffering), recovered packets feed the
shared ingest path (RR counts them received; `NACKScheduler.noteRecovered`
clears the gap without an RTT sample), the NACK reorder tolerances loosen in
place while parity flows and disarm after `TransportTuning.fecParityIdleNs`,
and the RR's `fecRecovered` field carries the raw-loss signal the sharer's FEC
arm needs — a faithful port of the mac client's receive-side FEC. Ingest now
drains all ready AUs per packet (`MultiCodecDepacketizer.drainReady`) so an
FEC-recovered tail packet with no trailing traffic still surfaces its frame.

Because `ViewerSession` now duplicates the mac client's loss-recovery core
almost verbatim, the natural next consolidation is to make the mac viewer
*reuse* it as its receive-side data plane (one tested implementation, run on
Linux CI every PR). The seam work that unblocks that — starting with making
the decoded video frame opaque to the session so a mac `CVPixelBuffer` flows
through zero-copy — lives in **`docs/mac-viewer-convergence.md`**.

*Landed:* the **viewer wiring** — `Packages/TailscreenLinuxBackends`, a SwiftPM package that plugs
the concrete backends into `ViewerSession`: `FFmpegVideoDecoder`
(FFmpegKit → `VideoDecoding`), `SDLVideoSink` (SDLKit → `VideoSink`),
`ALSAAudioSink` (ALSAKit → `AudioSink`), a `ViewerPipeline` assembler, and a
`tailscreen-viewer` executable driven by a tsnet `TsnetTransport` (the mac
client's `TailscaleNode` + `PacketListener` connect path, ported). Split so
the decode→render→audio path is CI-proven independent of tsnet:
`PipelineIntegrationTests` runs a real H.264 keyframe through
encode → production RTP packetizer → `ViewerSession` → FFmpeg decode →
collecting sinks (the Linux twin of `ScreenShareSyntheticFramesTests`), under
the `linux-viewer` CI job, which also link-checks the tsnet binary on Linux.
The one seam refinement this needed: `VideoDecoding.decode` now takes the
`codec` (forwarded from the RTP payload type via `au.codec`) so the decoder
picks H.264/HEVC deterministically instead of sniffing the bitstream. A *live*
tsnet run needs a real tailnet and stays local-only. Still open before a
shippable viewer: the outbound TCP back-channel (annotations / remote-control
send). (FEC ingest — previously listed here — has landed; see above.)

**Phase 3 — Linux sharer.** Portal capture → encoder adapter (#3, #4) →
the existing broadcast/fan-out logic, which is already extracted into pure
decision functions. Then admission UI, voice, system audio (#5, #6). Tray
UI last. (Remote-control injection via the RemoteDesktop portal (#2) is
deprioritized — the confinement question makes it the highest-risk piece,
and it isn't on the near path; see the effort note below.)

*Landed:* the **sharer data plane is portable**. `TailscaleScreenShareServer`
moved wholesale into `TailscreenKit`'s new `TailscreenSharer` target and
builds/tests on Linux under `linux-protocol`. The measurement that motivated
it: 4083 lines, of which exactly **two** were genuine Apple API usage (an
`NSImage` preview callback, one `SCStreamError`) — the rest was portable
logic that merely lived in a mac target. The blockers were bulk-mechanical,
not architectural: 41 `OSAllocatedUnfairLock` → `Synchronization.Mutex`,
plus those two API sites. Logging was already portable (`TSLogger: LogSink`).

The platform surface is now two protocols — **`CaptureEncoding`** (capture +
encode) and **`InputInjecting`** (remote-control injection) — and
`CaptureEncoding` is shaped from `CaptureHelperWire`'s `OutType`/`InType`,
because that seam already existed: the capture-helper IPC wire *was* a
portability boundary, just never named as one. `HelperScreenCapture` and
`RemoteControlInjector` conform with empty extensions. So the remaining
Linux-sharer work is a `CaptureEncoding` implementation (portal/PipeWire
capture + a libavcodec encoder honouring set-bitrate / force-keyframe /
set-frame-interval) and a host UI — *not* a reimplementation of admission,
fan-out, loss recovery, or congestion control.

Two things this also fixed rather than just moved: the encoder bitrate
formula now lives in `EncoderTuning.computeBitrate` beside
`defaultBitsPerPixel` (the server no longer reaches into the VideoToolbox
encoder for arithmetic), and `ScreenShareCaps.remoteControl` is advertised
**iff** the host supplied an injector, so a non-injecting sharer withholds
the bit instead of inviting control requests it can't serve — a distinction
a macOS-only server had no reason to make.

*Landed:* the **first `CaptureEncoding` backend**, so a Linux host can now
produce the pixels the portable server fans out.

- **`Packages/X11CaptureKit`** — X11 root-window capture (libxcb + MIT-SHM
  zero-copy, with a `GetImage` fallback) plus the BGRA→I420 conversion, in a C
  shim under a Foundation-only Swift wrapper. Colour is **limited-range
  BT.709**, matching the viewer's YUV shader exactly; the tests pin that by
  transcribing the shader's inverse, because a wrong range doesn't fail, it
  just ships a washed-out picture.
- **`FFmpegKit` grew an encoder** (`FFmpeg.VideoEncoder`) plus
  `NALUnit.annexBToAVCC` — the direction a non-Apple *sharer* needs, which
  problem #3 above says belongs in the shared adapter layer and which the test
  sharer had been reinventing privately. The encoder is configured for the
  transport's constraints rather than archival quality: no B-frames, keyframes
  on demand, and parameter sets in-band on **every** keyframe (no
  `GLOBAL_HEADER`), which is what lets a viewer join mid-stream.
- **`Packages/TailscreenLinuxBackends/Sources/TailscreenSharerLinux`** — `X11CaptureEncoder`, which
  satisfies `CaptureEncoding` and honours all three congestion levers. No
  helper subprocess: `replayd` is the only reason macOS isolates capture, and
  Linux has no equivalent (#10 above).

**CI gates both** — `linux-x11-capture` for the capture package, and
`linux-viewer` now runs under `xvfb-run` so the capture→encode→decode
integration test actually executes instead of self-skipping. That is the
payoff of doing X11 before the portal: **X11 capture is headlessly testable
under Xvfb; portal/PipeWire capture never can be** (session bus + compositor +
consent dialog). Wiring both behind `CaptureEncoding` buys a CI-gated capture
backend from day one, with the portal as the production Wayland path verified
locally — the same split that made the viewer's `linux-viewer` job possible.

Deliberate limits, all of them stated rather than silently degraded: display
shares only (a window/app selection is **refused**, since widening it to the
whole screen would leak what the user didn't pick), X11 only, no system-audio
capture (#5 remains the unsolved one), no `onPreviewImage` — the preview
thumbnail is published as raw pixels through `onPreviewThumbnail`, since that
seam's encoded-bytes shape exists for the mac helper's IPC boundary — and
**software
encoders only** — `h264_vaapi`/`h264_nvenc` are present in most libavcodec
builds and will happily be *found* by name, then fail to open without a
matching device, because they consume hardware frames this path never uploads.
Hardware encode is worth having and is its own piece of work, not a name in a
list.

**Verified live, Linux→Linux, over headscale.** `scripts/e2e-linux-sharer.sh`
brings up a local control plane, an Xvfb display with real content, a headless
sharer (`tailscreen-sharer-linux`: the portable server + the X11 backend) and a
headless viewer (`tailscreen-viewer-probe`: `TsnetTransport` + `ViewerSession` +
FFmpeg decode), and asserts on what arrives:

```
[sharer] READY hostname=ts-sharer ip4=100.64.0.1 fps=10
[sharer] viewers: 1 [100.64.0.2]
[probe]  admitted by sharer (serverCaps=23)
[probe]  first frame 1280x720
[probe]  PROBE_OK frames=16 size=1280x720 nonUniform=true
```

That's the first time the sharer data plane has served a viewer off macOS, and
three details in it are load-bearing. `nonUniform=true` means the decoded luma
varies — real captured pixels, not a flat rectangle that would satisfy a frame
count. `1280x720` matches the X display, so geometry survived
capture→encode→RTP→decode. And `serverCaps=23` is
`nack|receiverReport|fec|annotations` with **`remoteControl` (bit 3) absent** —
the conditional-capability change observed in the wild: no injector supplied,
so the bit is withheld.

Still open before a usable Linux sharer: a host UI (tray/window) driving
`TailscaleScreenShareServer`, the portal capture backend for Wayland, and
system audio.

**Phase 4 — Windows.** Viewer first, reusing the Phase 2/3 adapter
seams (capture/encode/decode/render/audio/input behind protocol-shaped
interfaces is the real deliverable of Phases 2–3). **Gated on a Windows
transport spike** (below) — the equivalent of Phase 1, but unproven and
therefore the schedule risk, so it must come first.

## Effort: viewer vs sharer, Linux vs Windows

The phases above are not equal-sized, and the asymmetry is worth stating
so the sequencing decisions are on record.

**A viewer is ~3× cheaper and lower-risk than a sharer, on either OS.**
A viewer *consumes* streams: its receive-side loss recovery (NACK/RR/FEC
depacketize), admission-as-viewer, annotation-send, and input-capture are
already portable and CI-tested, so what's new is a decoder (FFmpeg —
blessed path), a window (SDL/Vulkan or D3D11), and audio-out. Each has an
obvious right answer, and the result **ships standalone** ("watch a Mac's
screen from Linux/Windows"). A sharer *produces* streams: it adds three
new OS-integration edges (capture in, encode, and — deprioritized —
inject out) that each have no single blessed path, plus the interactive
consent surfaces. What already exists and shrinks the sharer: the entire
server **decision layer** (congestion, fairness, FEC sweep, admission,
retransmit) is portable and tested, the **control-plane listener** is
portable, and the **capture-helper wire protocol** is portable — the
sharer's "brain" is done; only the I/O edges are new.

**Linux sharer** — the schedule risks are (1) **capture**: PipeWire via
`xdg-desktop-portal` ScreenCast has no FFmpeg-equivalent blessed path
(portal negotiation, permission dialogs, DMABUF/SHM formats, compositor
and Wayland-vs-X11 differences), and (2) **encoder rate-control
calibration** (#4), which only proves out on a real impaired network.

**Windows sharer** — counterintuitively, the *media* side is **easier
than Linux**: Windows.Graphics.Capture is one well-documented WinRT API
with a built-in `GraphicsCapturePicker` capturing to D3D11 textures (no
portal/PipeWire/compositor zoo); WASAPI **loopback capture is
first-class** and process-exclusion loopback (Win10 21H1+) solves the
system-audio self-exclusion problem (#5) that needs filter-chain routing
on PipeWire; and Media Foundation ships an **in-box AAC** encoder (no
fdk-aac licensing, #6). Three of the six port problems are easier on
Windows, one (AVCC↔Annex-B, #3) is identical, one (#4) is the same
everywhere. The catch is the **substrate**, not the media: Swift-on-
Windows is officially supported but rougher than Linux (fewer runners,
less-complete `FoundationNetworking`); libtailscale as a Windows
c-archive/DLL has never been exercised (CGO needs a mingw/MSVC C
toolchain); and TailscaleKit needs a **third shim tier** beside patch 022
— WinSDK/Winsock for the syscalls (`closesocket`, `WSAPoll`, `SOCKET`
handles) whose semantics differ from POSIX. So the Windows risk is
"does the Swift + tsnet base stack come up at all," front-loaded into the
transport spike, rather than spread through the capture work like Linux.
Net: comparable total effort to the Linux sharer, different risk shape.

**Windows transport spike (Phase 4 gate).** Before any Windows capture
work: build `libtailscale.a`/`.dll` on Windows (Go c-archive with a C
toolchain), write the Windows shim tier for the TailscaleKit wrapper, get
`swift build` linking, and bring a tsnet node up against a local
headscale — the exact shape of Phase 1, but on the less-proven substrate.
The Windows **viewer** doubles as this spike: it forces the whole base
stack up before a line of capture code, and ships as a product if it
works. (Swift-on-Windows maturity moves fast — re-check its current state
when scheduling this, rather than trusting a dated assessment.)

Note on remote control: it's **deprioritized**, which shifts the
estimates. On Linux it was the *hardest* item — the app-share
pointer-confinement security property (#2) depends on global coordinates
Wayland hides, a design decision, not a compile-fix — so dropping it
removes the worst Linux unknown. On Windows injection would've been one
of the *easiest* items (`SendInput` is global and simple, no confinement
problem), so deprioritizing it helps Linux more than Windows.

**Continuous.** Migrate the pure test suites from the main package into
`TailscreenKit` so they run on Linux CI too — they test portable code but
historically imported the mac-only `Tailscreen` module. *In progress:* 17
suites (the loss-recovery/RTP/wire/util set — `RTPPacketTests`,
`FECCodecTests`, `FECGroupBufferTests`, `NACKSchedulerTests`,
`RetransmitBufferTests`, `RRAccountingTests`, `RTPBufferPoolTests`,
`RTPAudioTests`, `ReceiveLoopPolicyTests`, `CaptureHelperWireTests`,
`ScreenShareProtocolTests`, `ShareResponseProtocolTests`, `ShareLockTests`,
`QualitySettingsTests`, `TailscreenInstanceTests`, `ViewerZoomMathTests`,
`OpusAudioCodecTests`) now live in `TailscreenProtocolTests` and run under
`linux-protocol` (≈260 tests). Moving `defaultBitsPerPixel` from the mac
`VideoEncoder` onto the portable `EncoderTuning` was the only production
change it required. Still mac-side, blocked on a shared helper or a mac
symbol: `ParserFuzzTests`/`SoakTests` (fuzz `HelperScreenCapture` +
`ParserFuzzHarness`), `RTPLossyChannelTests`/`VoiceChannelTests` (share the
`LossyChannel` helper), `MacKeyCodeMappingTests` (the `keyModifiers(from:)`
leg uses `NSEvent.ModifierFlags`), `WireByteRegistryTests` (picker
framing), and the `RemoteControlPolicy`/`ViewerAccessPolicy` suites (mixed
mac symbols) — a follow-up can split the shared helpers into a
Linux-buildable test-support file to unblock the rest.
The flip of the macOS app to *depend on* the protocol package (instead of
the symlink-sharing Phase 0 started with) is done — the access-control
migration (internal → public across the module boundary, explicit
memberwise inits) was driven blind via macOS CI and converged in one
fixup round.

## Explicit non-goals (for now)

- iOS/Android viewers — different UI stacks entirely; the protocol would
  carry over, but nothing else here does.
- Feature parity on day one. The capability-negotiation design means a
  port can ship base video + PLI and grow into NACK/RR/FEC/audio/remote
  control release by release, interoperating the whole way.
