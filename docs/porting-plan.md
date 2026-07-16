---
title: Porting Plan (Linux & Windows)
nav_order: 10
permalink: /porting-plan/
---

# Porting plan: Linux & Windows

This is a working plan, not a commitment. It records what porting Tailscreen
off macOS actually involves: what carries over, what must be rebuilt per
platform, and the specific protocol/architecture problems a port surfaces —
several of which are worth fixing on macOS first, while there's only one
implementation to migrate.

**Status:** Phase 0 is done — the portable core builds and passes smoke
tests on Linux (`TailscreenProtocolPackage`, enforced by the `linux-protocol`
CI job). Everything below Phase 0 is proposal.

## What carries over as-is

- **Transport.** `libtailscale` is Go; tsnet is fully cross-platform.
  `go build -buildmode=c-archive` works on Linux today (Windows needs a
  spike — see Risks). Ephemeral-node identity, LocalAPI peer lookup, and
  the StableNodeID admission keying all carry over unchanged.
- **The wire protocol.** Every byte on port 7447 is pinned by
  `WireByteRegistryTests` and the round-trip suites, and the protocol was
  designed to degrade per capability (extended HELLO caps, unknown
  type-byte skip, PT auto-detect). A new client that implements only the
  base profile — HELLO, RTP depacketize, PLI — interoperates with every
  shipped macOS sharer, then earns NACK/RR/FEC incrementally by
  advertising caps.
- **The portable core (~6 k lines, 25 files).** RTP packetization, TCP
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
| Decode | VideoToolbox | FFmpeg (libavcodec) + VA-API hwaccel | Media Foundation / FFmpeg + D3D11VA |
| Render | Metal (`CAMetalLayer`) | Vulkan or OpenGL; SDL as the pragmatic first cut | D3D11 swapchain; SDL again viable |
| Voice + system audio | CoreAudio / AVFoundation / AudioToolbox AAC | PipeWire (capture + playback), codec: see AAC risk below | WASAPI (loopback capture is first-class), Media Foundation AAC |
| Remote-control injection | `CGEvent` + Accessibility TCC | `org.freedesktop.portal.RemoteDesktop` (consent UX ≈ TCC) | `SendInput` |
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
   the shared adapter layer, not be reinvented per platform.
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
6. **AAC on Linux is awkward.** fdk-aac is license-encumbered for
   distribution; FFmpeg's native AAC encoder is serviceable but worse.
   Consider negotiating **Opus** as an additional audio codec — a new
   payload type is a one-registry-row, capability-degrading change, and
   old viewers already drop unknown PTs silently.
7. **TailscaleKit's Swift wrapper needs a portability audit.** The C
   library is portable; the Swift wrapper + our patches (send/receive,
   `ListenPacket`, poll timeouts) were only ever built against Apple
   toolchains. Expect small fixes (no `os` logging, socket API
   differences), not a rewrite. `TailscalePeerDiscovery` /
   `TailscaleIPNWatcher` are Foundation + TailscaleKit only — they join
   the portable set the moment TailscaleKit builds on Linux.
8. **The app-state layer is Combine/SwiftUI-shaped.** `ObservableObject`
   / `@Published` don't exist off-Apple (this is why
   `ViewerAccessPolicyStore` stayed out of the portable set). Ports need
   their own thin state layer; keep the portable core free of Combine.
9. **Localization.** `L(_:)` rides `String(localized:bundle:)`, which is
   Apple-Foundation. Non-mac UIs need their own catalog mechanism; don't
   pull `Localization.swift` into the portable set.
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

**Phase 0 — portable core (done).** `TailscreenProtocolPackage` compiles
the wire protocol + decision logic on Linux with smoke tests; the
`linux-protocol` CI job keeps it that way.

**Phase 1 — transport spike (de-risks everything).** Build
`libtailscale.a` on Linux, patch TailscaleKit until `swift build` links and
a tsnet node comes up against a local headscale (native headscale on Linux
is easy — no Docker needed). Exit criterion: two Linux processes exchange
UDP datagrams over tsnet. This also unlocks moving `TailscalePeerDiscovery`
into the portable set and running the connectivity tests on Linux CI —
which GitHub's *Linux* runners may actually permit, unlike the macOS
sandbox that blocks the WireGuard handshake today.

**Phase 2 — Linux viewer.** Headless first: dial a macOS sharer, HELLO,
depacketize, FFmpeg-decode, assert on decoded frames (the Linux twin of
`ScreenShareSyntheticFramesTests`). Then an SDL/Vulkan window, audio
playback, PLI/NACK/RR/FEC (already in the portable core), annotations out,
and remote-control input capture (needs problem #1 solved). A viewer-only
Linux release is a shippable milestone on its own.

**Phase 3 — Linux sharer.** Portal capture → encoder adapter (#3, #4) →
the existing broadcast/fan-out logic, which is already extracted into pure
decision functions. Then admission UI, voice, system audio (#5, #6),
remote-control injection via the RemoteDesktop portal (#2). Tray UI last.

**Phase 4 — Windows.** Viewer first, reusing the Phase 2/3 adapter
seams (capture/encode/decode/render/audio/input behind protocol-shaped
interfaces is the real deliverable of Phases 2–3). Prerequisite spike:
libtailscale as a Windows c-archive/DLL plus Swift-on-Windows toolchain CI.

**Continuous.** Migrate the pure test suites (`RTPPacketTests`,
`FECCodecTests`, `NACKSchedulerTests`, `ParserFuzzTests`, …) from the main
package into `TailscreenProtocolPackage` so they run on Linux CI too — they
test portable code but currently import the mac-only `Tailscreen` module.
And eventually flip the macOS app to *depend on* the protocol package
instead of symlink-sharing its sources; that's an access-control migration
(internal → public across a module boundary) best driven by a compiler on
a Mac, which is why Phase 0 used symlinks.

## Explicit non-goals (for now)

- iOS/Android viewers — different UI stacks entirely; the protocol would
  carry over, but nothing else here does.
- Feature parity on day one. The capability-negotiation design means a
  port can ship base video + PLI and grow into NACK/RR/FEC/audio/remote
  control release by release, interoperating the whole way.
