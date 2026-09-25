# Bringing Tailscreen to Windows (swift-cross-ui / WinUI)

> **Status:** viewer and sharer both work end to end (W0–W7 shipped: signed-in
> viewer, video, audio, capture, remote control, DPI). x64 and arm64 both
> build, stage and pack into MSIX on every push (W8a/W8b/W9d shipped). What's
> left of packaging (W8): trusted code signing and the first real winget
> submission — the manifest templates exist but the shipped MSIX is
> self-signed, which winget rejects. See `docs/platform-support.md` for the
> user-facing feature matrix.

This is **L5** of the [Linux GTK viewer plan](linux-viewer-gtk-plan.md): the
same native-feeling desktop app on Windows, reusing everything the Linux
effort proved.

## Why most of it was already done

The hard, novel work was Linux (portable Swift: receive/send data planes,
tsnet transport, codec wrappers, chrome). Only the platform leaves needed
new code: `WASAPIKit` (audio out), a WinUI video surface (`Image`/
`WriteableBitmap`, `SwapChainPanel` later), `Windows.Graphics.Capture`-based
capture (`TailscreenSharerWGC`), and `SendInputKit` for injection. swift-cross-ui's
`WinUIBackend` ships `WinUIElementRepresentable` (a public `NSViewRepresentable`
analogue), so the video surface needed no private-API trick the way the
GTK app's `GtkVideoView` did.

**WGC over DXGI Desktop Duplication** for the sharer: Duplication only
captures a whole output, but WGC has a per-window picker matching macOS's
`SCContentSharingPicker` — sharing one window is the common case.

## The real blocker: libtailscale's Go↔native bridge

`tailscale.go`'s Go↔native handoff used `syscall.Socketpair(AF_LOCAL)` +
SCM_RIGHTS descriptor passing — both undefined on Windows, and Windows has
no AF_UNIX datagram mode at all (our UDP path needs `SOCK_DGRAM`). A spike
(`spikes/windows-tsnet-bridge/`, since deleted — its answer shipped as patch
024/025) proved a loopback-socket replacement works, including the load-bearing
detail that SCM_RIGHTS is unnecessary: Go and native code share one process
and one handle table, so the handle *value* suffices without descriptor
passing. Trap avoided: several Winsock wrappers in Go's `syscall`
(`Accept`, `Recvfrom`, `Sendto`, `SetsockoptTimeval`) compile on Windows but
are `EWINDOWS` stubs that always fail at runtime — code written against the
compiler's opinion alone builds clean and fails on first use.

**Escape route not taken for the sharer:** `tailscale_loopback()` +
SOCKS5 `udpAssociate` would let a Windows *viewer* skip the bridge
entirely, at the cost of an extra userspace hop per datagram. SOCKS5 gives
no `BIND`, so it can't serve the sharer's inbound listeners — this route
reaches a viewer and stops, which is why the bridge fix was still done.

## FFmpeg licensing

Tailscreen is MIT. The viewer only ever decodes, so it links **LGPL**
shared FFmpeg builds (not the GPL ones carrying libx264, which would
infect the app under MIT). `windows-ffmpeg` CI job tests this; whatever
packaging format ships, the FFmpeg/libopus DLLs must stay separately
replaceable and the LGPL text + relink offer must ship with the package.

## Toolchain

Swift on Windows (swift.org toolchain) + Windows App SDK; FFmpeg via
vcpkg/prebuilt; libtailscale per the bridge fix above (a patch series on
the fork, not a build flag). `Apps/windows` reuses `TailscreenViewerCore`/
`TailscreenViewerTsnet` and TailscreenKit's portable tiers.

**x64 vs arm64 use different Swift versions on purpose**, not by oversight:
x64 is pinned to Swift 6.1 (6.2/6.3 hit a swift-cross-ui frontend crash),
arm64 needs 6.3 (6.1's clang collides with the Windows SDK's
`_ARM64_BARRIER_ISH`; separately, cgo needs a MinGW-flavored C compiler for
the c-archive — llvm-mingw — because Swift's own clang targets
windows-MSVC and rejects the `-mthreads` flag cgo passes unconditionally).
Unifying the two is a follow-up once either blocker clears.

CI: `windows-viewer`/arm64 jobs build the app, run a headless self-test
(WARP software rasterizer for render read-back), and pack+sign+install+activate
an MSIX natively per architecture (`app-windows.yml`).

## What shipped, roughly in order

Bridge spike → real bridge (patches 024/025) → app renders on WinUI → app
reaches the tailnet and lists peers → video via `FFmpegVideoDecoder` (moved
to `Packages/TailscreenVideoFFmpeg` so consuming it doesn't drag in ALSA/X11)
→ audio via WASAPI (`Packages/WASAPIKit`, fronted by the now-portable
`ThreadedAudioSink`) → sharer via WGC + `SendInputKit` + `WinOverlayKit` →
per-monitor-v2 DPI awareness and the shared `TailscreenHubUI` chrome → MSIX
packaging on x64 then arm64. Each stage's rationale that still matters is
folded into the sections above; the step-by-step build log is not repeated
here.

## Packaging — decisions and why

Four mostly-independent choices, in the order that unblocks the rest:

1. **Self-contained Windows App SDK deployment, not the bootstrapper.**
   Landed (W9d). The pinned swift-winui targets WinAppSDK 1.5, so the
   bootstrapper only matched an installed 1.5 runtime — a machine with only
   1.6.x failed too. Self-contained mode stages the 1.5 framework payload
   beside the exe, patches swift-winui (CI-time patch, not a fork, so it's
   upstreamable) to `LoadLibrary` it directly, and embeds a reg-free WinRT
   manifest (896 activatable-class registrations) into the exe — without
   it, WinUI fails at first XAML type with `REGDB_E_CLASSNOTREG`. Cost:
   ~57 MB/arch uncompressed, and no more Microsoft runtime servicing (a
   WinAppSDK CVE fix means re-releasing the app).
2. **Signing is the long pole.** Since June 2023, OV/EV signing keys must
   live on FIPS 140-2 hardware, so a `.pfx` in CI secrets (the macOS
   pattern) no longer works for a new cert. Candidates: a cloud signing
   service (Azure Trusted Signing, DigiCert KeyLocker, SSL.com eSigner), a
   hardware token on a self-hosted runner, or **SignPath** (free OSS tier +
   GitHub Actions integration — the obvious first call for an MIT
   project). Unsigned isn't neutral: SmartScreen warns on download/first
   run, which lands badly for an app requesting screen capture and input
   injection. **Not started.**
3. **Installer format: MSIX**, chosen over Inno Setup/WiX/Velopack because
   it resolves the WinAppSDK framework dependency through the package graph
   (moot now with self-contained mode, but also gives clean
   install/uninstall, differential updates, and winget/Store eligibility).
   Already built by CI on every push, for both architectures.
4. **Distribution: winget first, Scoop second, Chocolatey if asked.**
   winget ships with Windows 11 and takes a declarative manifest (already
   drafted in `Apps/windows/packaging/winget/`, templated — see its
   README for what a submission needs). Chocolatey's audience (fleet
   provisioning via PowerShell-scripted packages) doesn't match a P2P
   screen-share GUI's early users.

## Open items

- **Trusted signing.** Nothing chosen or started; blocks a real winget
  submission (winget validates the MSIX signature chains to a trusted
  root — a self-signed MSIX is rejected).
- **First winget submission.** Manifest templates exist
  (`Apps/windows/packaging/winget/`); needs a signed release to fill in.
- **Throughput of the Go bridge is unmeasured** — it adds a copy per
  datagram; matters once real users push real bitrates.
- **Startup flakiness** (`0xC000001D`/`0xC0000409`, both Swift-fatalError
  exit codes): one known cause fixed (double `SetProcessDpiAwareness`
  between the app and swift-winui — the app no longer sets it itself); if
  it clusters again, it isn't fully explained.
- **`SwapChainPanel` + D3D11 rendering** is the intended replacement for
  the current CPU `WriteableBitmap` blit; not started, and needs
  `DXGI_ERROR_DEVICE_REMOVED` handling for driver resets/sleep that the
  CPU path doesn't have (the CPU path has no such failure mode, which is
  why it shipped first).
- **One Swift toolchain for both architectures** once the 6.1/6.3 split
  above stops being necessary.
- **Headless D3D render verification** is unproven past the CPU path — a
  bitmap blit can be read back and asserted on directly, but WARP's
  determinism for a real D3D11 swap chain hasn't been tested. Degrade to a
  compile gate + documented manual check if it proves flaky.

CI reached the current green state by working through, in order: an x86_64
assembler fed ARM64 assembly (wrong gcc on the arm64 runner), a Windows-SDK/
Swift-6.1-clang header collision (`_ARM64_BARRIER_ISH`), cgo assuming a
MinGW-flavored C compiler where Swift's own clang targets MSVC, a probe that
ran without the Swift runtime beside it, and two rounds of an x64 vcruntime
DLL leaking into the arm64 staged output. None of those fixes are expected to
regress, but they explain why arm64 support is its own phase rather than "a
URL change" on top of x64 — three of the five were upstream toolchain
mismatches with no fix inside this repo.

## Threading model

Same as the GTK app: the `@MainActor` transport Task interleaves with the
WinUI dispatcher loop; `FrameStore`'s lock + value-type COW hand-off is
what makes the cross-thread frame delivery safe regardless of backend.
