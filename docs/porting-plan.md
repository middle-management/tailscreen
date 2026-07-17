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

**Status:** Phases 0 and 1 are done — the portable core (a real SwiftPM
dependency of the app since the flip) builds and passes smoke tests on
Linux, TailscaleKit builds and tests on Linux, and the live two-node tsnet
exchange is verified (see Phase 1 below). Phases 2+ are proposal.

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
| Decode | VideoToolbox | FFmpeg (libavcodec) + VA-API hwaccel | Media Foundation / FFmpeg + D3D11VA |
| Render | Metal (`CAMetalLayer`) | Vulkan or OpenGL; SDL as the pragmatic first cut | D3D11 swapchain; SDL again viable |
| Voice + system audio | CoreAudio / AVFoundation for I/O; **Opus** (OpusKit/libopus) codec — done | PipeWire (capture + playback); Opus already portable | WASAPI (loopback capture is first-class); Opus already portable |
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
6. **~~AAC on Linux is awkward.~~ RESOLVED — switched to Opus.** fdk-aac is
   license-encumbered for distribution and FFmpeg's native AAC encoder is
   worse, so rather than negotiate a second codec we replaced AAC outright
   with **Opus** (royalty-free, software-only, portable). It lives in the
   local `OpusKitPackage` (a `systemLibrary` wrapper over libopus, CI-gated
   on Linux by `linux-opus`) and is wired into the app via
   `Sources/OpusAudioCodec.swift` (`OpusVoiceEncoder`/`OpusVoiceDecoder`,
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
