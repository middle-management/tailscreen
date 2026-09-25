# Porting plan: Linux & Windows

> Status: shipped. Linux (`Apps/linux`, GTK4) and Windows (`Apps/windows`,
> WinUI) apps exist with full sharer+viewer parity including remote control,
> annotations, notifications, hotkeys, and voice/audio — see
> `.claude/rules/linux.md` / `.claude/rules/windows.md` for current
> architecture and pitfalls. This doc keeps the *why* behind decisions made
> while porting and the still-open gaps; treat the phase/effort narrative
> below as history, not a roadmap.

## Goal

Port off macOS-only without forking the protocol or the server "brain":
same wire protocol, same admission/congestion/FEC decision logic, new
per-platform capture/encode/decode/render/input/audio edges only.

## What had to be rebuilt per platform

Capture, picker, encode, render, and remote-control injection all needed
platform-native replacements for ScreenCaptureKit/VideoToolbox/Metal/CGEvent
— see `.claude/rules/linux.md` and `.claude/rules/windows.md` for what
shipped where. Two edges worth calling out specifically, since other
packages point here for the reasoning:

- **Decode**: VideoToolbox has no off-Apple equivalent; `libavcodec` was the
  obvious choice, wrapped in `Packages/FFmpegKit` rather than one of the
  AVFoundation-bound Swift FFmpeg wrappers on the package index.
- **Voice + system audio**: Opus (portable) for the codec; device I/O is
  ALSA on Linux (`Packages/ALSAKit`) and WASAPI on Windows
  (`Packages/WASAPIKit`), each behind the same portable RTP/encode path.

## Key decisions and why

- **Capability-negotiated protocol, not feature parity on day one.** Every
  wire byte is pinned (`WireByteRegistryTests`); a new client implementing
  only base HELLO/RTP/PLI interoperates with any shipped sharer and grows
  into NACK/RR/FEC/audio by advertising caps. This is why a Linux/Windows
  port could ship incrementally instead of as one big-bang release.
- **`InputEvent` rewritten off the mac key model (pre-1.0 breaking change,
  done).** The wire now carries USB HID usage IDs + a platform-neutral
  `KeyModifiers` set instead of `CGKeyCode`/`CGEventFlags`. Rejected
  alternative: per-platform translation tables keyed on the old mac wire
  shape — would have made every new platform special-case mac instead of
  targeting one neutral shape (macOS itself now goes through
  `MacKeyCodeMapping`).
- **AAC replaced outright with Opus (#6, done)**, rather than negotiating a
  second codec: fdk-aac is license-encumbered for distribution and FFmpeg's
  native AAC encoder is worse. Portable, royalty-free, wired via
  `Packages/OpusKit`. No negotiation needed — pre-1.0, no deployed
  AAC-only peers.
- **AVCC/Annex-B conversion lives in the shared adapter layer (#3, done)**,
  not reimplemented per platform: `Packages/FFmpegKit`'s
  `NALUnit.avccToAnnexB`/`annexBToAVCC`, since VideoToolbox emits AVCC and
  every non-VT codec speaks Annex-B by default.
- **No helper-subprocess requirement off macOS (#10).** `replayd`/TCC
  coupling is the only reason macOS isolates capture in a subprocess;
  Linux/Windows portal/WGC consent flows don't need it, so both ports run
  capture in-process. Helper isolation stays an *option* for crash
  containment, not a porting requirement.
- **X11 capture built before the Wayland portal.** X11 (libxcb+MIT-SHM) is
  headlessly testable under Xvfb; portal/PipeWire capture never is (needs a
  real session bus, compositor, consent dialog). Building X11 first bought
  a CI-gated capture backend from day one (`linux-x11-capture`,
  `linux-viewer` under `xvfb-run`), with the portal verified locally as the
  production Wayland path. Same split later applied to the viewer's
  FFmpeg/SDL/ALSA CI job.
- **Portable core extracted as its own SwiftPM target**, not shared via
  `#if os()` inside the mac app. `TailscreenProtocol`/`TailscreenSharer`/
  `TailscreenViewer` (Packages/TailscreenKit) own the wire, loss-recovery,
  congestion, and server/viewer decision logic; only ~2 lines of the
  4083-line sharer server turned out to be genuine Apple API. This is why
  the sharer port was "new I/O edges only," not a rewrite.
- **App-share pointer confinement dropped on Linux, remote-control
  deprioritized there accordingly (#2).** Wayland hides global desktop
  coordinates, so the mac security property (clamp injection to an app's
  window-rect union) has no portal equivalent — shipped anyway via
  whole-stream confinement rather than blocking on redesigning the
  property. On Windows, by contrast, `SendInput` is global and simple, so
  remote control was easy there — the risk was asymmetric, not shared.
- **Localization needed no mac-only fallback, in the end.** The `.lproj`
  catalog *format* was never mac-specific, only Foundation's *lookup* was;
  `Packages/TailscreenL10n` keeps the format and reimplements resolution in
  plain Swift, so all three apps share one catalog.

## Still open / known gaps

- **Linux portal (Wayland) capture not wired into `Apps/linux`** — backend
  selection code exists (`Packages/PortalCaptureKit`,
  `TailscreenSharerPortal`) but the app still only offers X11 capture; see
  `.claude/rules/linux.md`.
- **System-audio capture on Linux (#5) unsolved.** macOS's
  `excludesCurrentProcessAudio` self-exclusion has no ALSA/PipeWire
  equivalent without explicit sink/filter-chain routing; not designed yet.
- **Hardware video encode (VA-API/NVENC) not implemented** — Linux sharer
  uses software encode only; `h264_vaapi`/`h264_nvenc` would need
  hardware-frame upload this path never does.
- **A handful of test suites remain mac-only**, blocked on shared test
  helpers or mac symbols: `ParserFuzzTests`/`SoakTests`,
  `RTPLossyChannelTests`/`VoiceChannelTests`, `MacKeyCodeMappingTests`,
  `WireByteRegistryTests`, the `RemoteControlPolicy`/`ViewerAccessPolicy`
  suites. Splitting shared helpers into a Linux-buildable test-support file
  would unblock the rest — see `test-catalog` skill before adding new ones.
- **Mac viewer does not yet reuse `ViewerSession`** (the Linux/Windows
  receive-side data plane) as its own receive path — tracked separately in
  `plans/mac-viewer-convergence.md`.
- Related, more detailed platform plans: `plans/linux-viewer-gtk-plan.md`,
  `plans/viewer-windows-plan.md`.

## Explicit non-goals (still true)

- iOS/Android viewers — the protocol would carry over, the UI stack
  wouldn't.
- Feature parity as a release gate — capability negotiation means each
  platform grows into NACK/RR/FEC/audio/remote-control incrementally.
