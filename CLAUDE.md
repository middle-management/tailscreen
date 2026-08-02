# CLAUDE.md

Guidance for Claude (and other AI assistants) working in this repo. Keep it accurate — if you change the build, layout, or protocol, update this file in the same commit.

## Project

**Tailscreen** is a macOS 15+ app for low-latency, encrypted peer-to-peer screen sharing over Tailscale. The UI is a regular docked main window (sign-in, accounts, the peer list — the hub) plus a menubar item that acts as the sharer tool (share status, start/stop, mic/system-audio/drawing controls). Viewer approvals and remote-control requests render on **both** surfaces, sharing the same components, so a sharer never has to hop between them to answer a prompt. It uses tsnet ephemeral nodes (no manual device registration), captures via ScreenCaptureKit, encodes H.264/HEVC with VideoToolbox, and renders with Metal. SwiftPM only — no Xcode project.

## Tech stack

- **Swift 6** with strict concurrency (`@MainActor`, `Sendable`).
- **macOS 15.2 (Sequoia)** deployment target. Not iOS. The 15.2 floor (vs. 15.0) is dictated by the `SCContentFilter.includedDisplays` / `includedWindows` / `includedApplications` getters the picker-helper uses to extract primitives.
- **Go 1.21+** required at build time to compile `libtailscale.a` (the C archive that TailscaleKit wraps).
- **libopus** required at build time: the app links it (via `./Packages/OpusKit`'s `COpus` systemLibrary) for the Opus audio path. Install with `brew install opus` (macOS) / `apt install libopus-dev` (Linux); pkg-config resolves it.
- **SwiftUI** (`Window` main scene + `MenuBarExtra` sharer tool; the app runs at `.regular` activation policy — Dock icon, always-reachable menu bar), **ScreenCaptureKit**, **VideoToolbox**, **Metal** (`CAMetalLayer`).
- **TailscaleKit** consumed as a local SwiftPM package (`./Packages/TailscaleKit`); **OpusKit** likewise (`./Packages/OpusKit`).

Runtime needs: Screen Recording permission, and either interactive Tailscale login or `TAILSCREEN_TS_AUTHKEY` (+ optional `TAILSCREEN_TS_CONTROL_URL`).

## Repository layout

```
tailscreen/
├── Apps/
│   ├── macOS/                  # The macOS app — a SwiftPM package (run app
│   │   │                       #   `swift` commands from THIS directory)
│   │   ├── Package.swift
│   │   ├── Sources/            # Tailscreen executable (Swift)
│   │   ├── Tests/TailscreenTests/  # Unit + connectivity tests
│   │   └── Resources/          # Tailscreen.icns (release .app packaging)
│   ├── linux/                  # The runnable native LINUX app (sharer +
│   │   │                       #   viewer) — a swift-cross-ui/GTK4 app reusing
│   │   │                       #   TailscreenLinuxBackends + the shared Tsnet
│   │   │                       #   transport + the shared TailscreenHubUI
│   │   │                       #   chrome, with a GtkGLArea YUV renderer, and
│   │   │                       #   a click-through CGtkOverlay window that
│   │   │                       #   renders viewers' annotations on the sharer's
│   │   │                       #   own screen (see Common pitfalls).
│   │   │                       #   Package `tailscreen-linux`, exe `tailscreen`
│   │   ├── Package.swift
│   │   ├── README.md
│   │   ├── Sources/{TailscreenViewerGtk,CGtkVideo,CGtkOverlay,CGtk4Sys,tailscreen}/
│   │   └── packaging/          # AppImage / tarball / flatpak / homebrew
│   └── windows/                # The runnable native WINDOWS app — swift-cross-ui
│       │                       #   on WinUI, reusing the portable tiers + the
│       │                       #   shared tsnet transport + TailscreenHubUI:
│       │                       #   sign-in, peer list, libavcodec video into a
│       │                       #   WinUI WriteableBitmap, WASAPI audio, and
│       │                       #   sharing via the WGC picker +
│       │                       #   TailscreenSharerWGC (with remote control and
│       │                       #   annotations, both gated on the capture item's
│       │                       #   screen rect resolving — see WinOverlayKit)
│       ├── README.md
│       ├── Sources/tailscreen/
│       └── packaging/          # MSIX manifest + assets, winget manifests
├── Packages/                   # Local SwiftPM packages the app depends on
│   ├── TailscreenKit/          # Portable (Linux-buildable) protocol core —
│   │   │                       #   a real dependency of the app (see its README)
│   │   └── Sources/{TailscreenProtocol,TailscreenTransport,TailscreenAudio}/
│   ├── TailscreenLinuxBackends/ # Linux platform BACKENDS — a library package
│   │   │                       #   wiring FFmpegKit+ALSAKit into the
│   │   │                       #   ViewerSession core, and X11CaptureKit+
│   │   │                       #   FFmpegKit into the sharer's CaptureEncoding
│   │   │                       #   seam. A Package, not an App, because it
│   │   │                       #   ships no runnable product the user launches
│   │   │                       #   — Apps/linux consumes it. The tsnet
│   │   │                       #   transport is NOT here — see
│   │   │                       #   TailscreenViewerTsnet. Also carries the
│   │   │                       #   headless test-sharer / sharer / viewer-probe
│   │   │                       #   executables used by the local E2E scripts
│   │   ├── Sources/{TailscreenViewerCore,TailscreenSharerLinux}/
│   │   └── Tests/TailscreenViewerCoreTests/  # real-decode pipeline test
│   ├── OpusKit/                # systemLibrary wrapper over libopus — the app's
│   │   │                       #   audio codec (replaced AudioToolbox AAC);
│   │   │                       #   see its README
│   ├── FFmpegKit/              # systemLibrary wrapper over libavcodec — the
│   │   │                       #   portable viewer's H.264/HEVC decoder AND the
│   │   │                       #   Linux sharer's encoder (not used by the mac
│   │   │                       #   app); see its README
│   ├── TailscreenVideoFFmpeg/  # libavcodec behind the portable VideoDecoding
│   │   │                       #   seam — shared by the Linux and Windows
│   │   │                       #   viewers. Its own package so consuming the
│   │   │                       #   decoder doesn't drag in ALSA/X11 (Packages/TailscreenLinuxBackends)
│   │   │                       #   or make linux-protocol need libavcodec
│   ├── XTestInjectKit/         # C shim over X11's XTEST + the Swift injector —
│   │                           #   the LINUX sharer's InputInjecting backend,
│   │                           #   i.e. what SendInputKit is on Windows. The C
│   │                           #   part exists for a different reason than
│   │                           #   CSendInput's: nothing in Xlib is
│   │                           #   unrepresentable in Swift, but XTestFakeKey
│   │                           #   takes a KEYCODE (this machine's keymap,
│   │                           #   meaningless off-host) while the wire carries
│   │                           #   HID usages — so X11KeyCodeMapping does
│   │                           #   HID→KEYSYM in the portable tier and only the
│   │                           #   XKeysymToKeycode hop needs a live Display.
│   │                           #   `xtest-probe` is the link check, the keysym
│   │                           #   audit, and the live Xvfb injection gate
│   ├── X11CaptureKit/          # C shim over libxcb + MIT-SHM — the Linux
│   │   │                       #   sharer's screen capture + BGRA→I420
│   │   │                       #   (limited-range BT.709); see its README
│   ├── ALSAKit/                # systemLibrary wrapper over libasound (ALSA) —
│   │   │                       #   the Linux viewer's audio-playback backend
│   │   │                       #   (Linux-only; wired via Packages/TailscreenLinuxBackends); see README
│   ├── WASAPIKit/              # C++ shim over WASAPI shared-mode rendering — the
│   │   │                       #   WINDOWS viewer's audio-playback backend, i.e.
│   │   │                       #   what ALSAKit is on Linux. Nothing to install
│   │   │                       #   (WASAPI ships with Windows); see its README
│   ├── TailscreenHubUI/        # The hub's LOOK, shared by both swift-cross-ui
│   │                           #   apps (GTK viewer + Windows app): HubStyle
│   │                           #   tokens, the header, the screen rows and
│   │                           #   their detail panes, the login/share cards,
│   │                           #   the session placard, the over-video chrome,
│   │                           #   and the header's PeerListFilter menu (a
│   │                           #   Menu of Toggles — swift-cross-ui has no
│   │                           #   popover and no custom menu label, but both
│   │                           #   its backends render checked menu rows).
│   │                           #   Extracted from Apps/linux when the
│   │                           #   Windows app needed the same design system —
│   │                           #   SwiftCrossUI + TailscreenProtocol only, no
│   │                           #   transport type, so Linux CI typechecks it on
│   │                           #   the Windows app's behalf; see its README
│   ├── WinOverlayKit/          # The WINDOWS sharer's annotation overlay: a
│   │                           #   click-through layered window fed by the
│   │                           #   portable AnnotationRasterizer. Tiny on
│   │                           #   purpose — UpdateLayeredWindow takes a
│   │                           #   premultiplied BGRA bitmap, so the missing
│   │                           #   piece was a rasterizer, not a drawing API,
│   │                           #   and a rasterizer is testable arithmetic.
│   │                           #   The window OWNS A THREAD with a message
│   │                           #   pump: annotations arrive on a network
│   │                           #   thread, and a window whose thread never
│   │                           #   pumps is one Windows treats as hung
│   ├── SendInputKit/           # C shim over Win32 SendInput + the Swift
│   │                           #   injector — the WINDOWS sharer's
│   │                           #   InputInjecting backend, i.e. what
│   │                           #   RemoteControlInjector is on macOS. C only
│   │                           #   because INPUT carries an anonymous union;
│   │                           #   every decision is in Swift and tested on
│   │                           #   Linux through an inject-nothing seam. Also
│   │                           #   owns the process's DPI awareness, because it
│   │                           #   owns the coordinate space that setting
│   │                           #   governs (see Common pitfalls)
│   ├── TailscreenSharerWGC/    # The WINDOWS sharer's CaptureEncoding backend:
│   │                           #   WGC frames → BGRAToI420 → libavcodec. Its own
│   │                           #   package specifically so it carries NO WinUI —
│   │                           #   which is what lets Linux CI typecheck it
│   │                           #   (linux-viewer job) instead of only a Windows
│   │                           #   runner. Counterpart of Packages/TailscreenLinuxBackends's
│   │                           #   TailscreenSharerLinux
│   ├── WGCCaptureKit/          # C++/raw-WinRT shim over Windows.Graphics.Capture
│   │   │                       #   — the WINDOWS sharer's screen capture. The
│   │   │                       #   picker + per-window model that matches macOS's
│   │   │                       #   SCContentSharingPicker, not DXGI Duplication's
│   │   │                       #   whole-output-only. Hands back BGRA; BGRAToI420
│   │   │                       #   does the conversion
│   └── TailscaleKit/           # Wraps libtailscale
│       ├── upstream/libtailscale/  # Git submodule (tailscale/libtailscale)
│       ├── Sources/  lib/  include/  # Symlinks into upstream
│       ├── Patches/            # .patch files applied to upstream Swift
│       ├── Modules/libtailscale/   # Module map for the C library
│       └── libtailscale.pc     # pkg-config file (used via PKG_CONFIG_PATH)
├── e2e/docker-compose.yml      # Local headscale control plane (port 8080)
├── scripts/e2e-{up,down,test}.sh
├── .github/workflows/
├── Makefile                    # Top-level build entry
└── test-local.sh               # Multi-instance local launcher
```

Use `rg` to find specific files; the layout above is enough orientation.

## Build & run

Always go through `make` — the root Makefile sets `PKG_CONFIG_PATH=$(CURDIR)/Packages/TailscaleKit` so SwiftPM's `systemLibrary` target finds `libtailscale.pc`, which in turn supplies the `-L` flag for `libtailscale.a`.

```bash
make build         # builds libtailscale.a, then `swift build`
make run           # build + run debug binary
make release       # swift build -c release   → Apps/macOS/.build/release/Tailscreen
make install       # release + copy to ~/bin/Tailscreen
make clean         # swift package clean + rm .build + clean TailscaleKit
make test          # swift test (after libtailscale)
make test-protocol # build + smoke-test the portable TailscreenProtocol package
                   #   (no libtailscale, no Apple frameworks — also runs on Linux)
make e2e-up        # start local headscale (Docker)
make e2e-down      # tear down headscale + volume
make test-e2e      # one-shot: e2e-up → swift test --filter TailscaleConnectivityTests → e2e-down
```

The app package lives in `Apps/macOS/` — bare `swift` commands for the app must run from that directory (from the repo root there is no manifest at all). And running `swift build` there before `make tailscale` will fail to link — you need `libtailscale.a` first.

First build downloads Go modules; **network access required**.

### TailscaleKit submodule

`Packages/TailscaleKit/upstream/libtailscale` is pinned in `.gitmodules` (`ignore = dirty`). After a fresh clone, run `git submodule update --init --recursive` (or clone with `--recurse-submodules`).

Patches in `Packages/TailscaleKit/Patches/*.patch` are applied on top of the upstream Swift sources. They add things like a `Foundation` import, glue imports for C-bridge types, `send`/`receive` on connections, public `logout`, listener poll-timeout handling, the `tsnet ListenPacket` / `PacketListener` Swift wrapper used by the UDP video path, a short-write-safe `OutgoingConnection.send` loop (patch 023 — replaced the app-side reflection hack that reached the private fd), Linux portability gates (patch 022 — Combine→AsyncStream fallback, Glibc syscall shim, `FoundationNetworking` imports, SOCKS-free direct-loopback LocalAPI), the **Windows bridge seam** (patch 024 — see below), and the **Windows Go-runtime start** (patch 026 — see below). **Do not edit `Packages/TailscaleKit/Sources/`** — those are symlinks into the submodule. Add or modify a patch instead, then re-run `make tailscale`. A new patch must be a sequential diff against the fully-patched tree (see `Patches/README.md` — the Makefile hard-fails on rejected hunks; `|| true` used to hide them and let GNU patch double-apply).

The **Go↔C socket bridge** (patch 024) is the platform seam under
`tailscale.go`. tsnet conns are userspace-WireGuard with no OS descriptor, so
libtailscale bridges each to a real socket pair and hands C one end. Upstream
does that with `socketpair(2)` plus SCM_RIGHTS descriptor passing for accepted
connections — **neither exists on Windows** (`syscall.Socketpair`/`AF_LOCAL` are
undefined for `GOOS=windows`; Win10 1803+ has AF_UNIX stream sockets but no
`socketpair()` and no datagram mode, which patch 013's UDP video path needs).
So both flavours moved behind `bridge.go`'s `bridgeStream` / `bridgePacket` /
`bridgeConnSender` interfaces, with `bridge_unix.go` (unchanged behaviour) and
`bridge_windows.go` (loopback TCP/UDP pairs; the accept handoff writes the
handle *value*, since Go and C share one process and one handle table, so
SCM_RIGHTS is unnecessary). Watch out when extending it: `syscall.Accept`,
`Recvfrom`, `Sendto` and `SetsockoptTimeval` **compile on Windows but are
`EWINDOWS` stubs that always fail at runtime** — which is why the Windows accept
goes through Go's `net` package. `libtailscale.a` now builds for
`windows/amd64`, proven by the `Windows build / Swift 6.1` job, which builds the
c-archive, links it into the app, and runs `tsnet-probe` against it. A node that
reaches a real tailnet on Windows is still unproven.

The **Go runtime start on Windows** (patch 026) is the other half of making
that archive usable. A Go c-archive does not start its own runtime: it asks
the C runtime to call `_rt0_amd64_windows_lib`, and until that happens every
cgo entry point blocks in `_cgo_wait_runtime_init_done` — no timeout, no
error, no log line. Go asks through a **`.ctors`** section
(`cmd/link/internal/ld/pe.go`: "addInitArray adds .ctors COFF section"), which
is the GNU convention that MinGW's startup objects walk. Swift on Windows is
an MSVC toolchain: its CRT walks `.CRT$XCA`…`.CRT$XCZ` and has never read
`.ctors`, so the initialiser ships in the executable and is never called. The
app froze on Sign in with two log lines and nothing after; `GODEBUG=inittrace=1`
printed nothing at all, because there was no runtime to trace. Nothing in the
build can catch this — every symbol resolves and the app starts fine.
`Sources/CGoRuntimeInit` (a C target, a no-op everywhere but Windows) registers
the entry point in `.CRT$XCU` **and** exposes an idempotent
`ts_go_runtime_start()` that patch 026 calls from `TailscaleNode.init` before
`tailscale_new()` — the section entry gives Go its documented timing, the
explicit call guarantees the object is linked at all and that the runtime is
starting regardless. The Windows CI job runs `tsnet-probe` and fails if node
creation does not return, so a regression here is a red build rather than a
frozen desktop.

**TailscaleKit builds and passes its tests on Linux** (Go c-archive + Swift wrapper; CI job `linux-tailscalekit`). The live two-node tsnet exchange (TCP + UDP `PacketListener` + LocalAPI over local headscale via `scripts/e2e-up-native.sh`, which is OS-aware) has been verified manually on a Linux host — see `docs/porting-plan.md` Phase 1.

## Testing

### Unit tests
```bash
make test
# or: export PKG_CONFIG_PATH="$(pwd)/Packages/TailscaleKit"
#     cd Apps/macOS && swift test
```

### E2E connectivity (real tsnet transport)

Two paths:

1. **Local headscale (preferred for CI/dev):**
   ```bash
   make test-e2e         # one-shot
   # or, manually:
   eval "$(make e2e-up)" # exports TAILSCREEN_TS_AUTHKEY + TAILSCREEN_TS_CONTROL_URL
   swift test --filter TailscaleConnectivityTests
   make e2e-down
   ```
   `scripts/e2e-up.sh` boots `e2e/docker-compose.yml` (headscale on `localhost:8080`), creates a user, and mints a reusable ephemeral pre-auth key.

2. **Real tailnet:** export your own `TAILSCREEN_TS_AUTHKEY` from the Tailscale admin console and run `swift test`.

3. **Docker-free headscale (local, no Docker):** `scripts/e2e-up-native.sh` downloads the pinned headscale release binary (keep `HEADSCALE_VERSION` in lockstep with `e2e/docker-compose.yml`), runs it natively, and emits the same env exports; tear down with `scripts/e2e-down-native.sh`. Useful on machines without Docker.

**These tsnet suites can't run on CI.** Tried on `macos-latest` via the native script: headscale came up healthy, but the first tsnet `node.up()` hung — GitHub's hosted macOS runner sandbox doesn't let the userspace-WireGuard handshake / DERP-STUN (`:3478/udp`) complete, and `node.up()` has no internal timeout. So anything that brings up a tsnet node (`TailscaleConnectivityTests` and all the screen-share E2E suites) is local-only. Only the pure-logic suites (`AdaptiveBitrateTests`, `VideoCodecTests`, `VoiceChannelTests`, `RTPPacketTests`, `RTPLossyChannelTests`, etc.) run on CI.

`RTPLossyChannelTests` is the CI-able stand-in for the impairment harness: it runs the real packetize → `LossyChannel` (deterministic, seeded loss/reorder/duplication) → depacketize pipeline and asserts recovery (reordering/duplication never drop or tear frames; genuine loss is signaled and the pipeline never wedges). It also closes the **NACK-recovery loop** (packetize → seeded loss → `NACKScheduler` + depacketizer → retransmit re-injection): loss recovered by NACK with zero PLIs and no torn frames, PLI fallback when retransmits also drop (never wedges), and small reordering producing neither NACK nor PLI. Its **FEC leg** (`runRecoveryLoop`: server-side `groupRanges` + `parityBody` per frame, viewer-side FEC-mode scheduler + `FECGroupBuffer` in front of the depacketizer) pins the layered handoff: seeded ≤1-loss-per-group recovered with zero NACKs/PLIs (H.264 + HEVC), ~10 % loss handing multi-loss groups to NACK with no torn frames, dropping every parity datagram reproducing today's NACK behavior exactly, and a late original after its FEC recovery changing nothing. `LossyChannel` (in `Apps/macOS/Tests/`) is reusable by any in-process packet test. It can't impair the live tsnet path — for that, see `scripts/net-impair.sh` (local-only).

Connectivity tests skip or fail without an auth key — that's expected.

### Local screen-share E2E (LOCAL ONLY)

These test surfaces exercise the screen-share pipeline beyond what GitHub Actions can run — its macOS runners can't grant Screen Recording TCC, can't host a real display, and `replayd`/`SCStream` won't come up. Most run over local-headscale tsnet with the server in `filterData: nil` mode (no capture-helper), so they're headless and need no Screen Recording permission.

1. **`ScreenShareSyntheticFramesTests`** — server (no helper) + real client over local-headscale tsnet, pre-encoded AVCC injected into the broadcast path. Asserts on `client.onDecodedFrameForTesting` (decode signal — the renderer's display-link render path needs an on-screen view, which xctest lacks). CI-eligible (skips if VideoToolbox produces no output, e.g. virtualized runners).
2. **`ScreenShareCaptureHelperTests`** — full pipeline including the real `--capture-helper` subprocess against the main display, hosted in a real on-screen `NSWindow` so the Metal **render** path runs and `renderer.onVideoSizeChanged` fires. Jiggles the cursor to keep ScreenCaptureKit delivering frames (a static screen starves the encoder). Local-only — self-skips on `CI` / `GITHUB_ACTIONS`. First run pops macOS's Screen Recording permission prompt on `Apps/macOS/.build/debug/Tailscreen`; subsequent runs are unattended.
3. **`ScreenShareFanoutTests`** — two viewers on one server: asserts video fan-out (both decode one broadcast) and audio relay (one viewer's RTP reaches the sharer locally **and** is relayed to the other viewer, gated by the server-assigned SSRC). A second test (`testSystemAudioReachesBothViewers`) injects a real `OpusVoiceEncoder` AU via `broadcastSystemAudioForTesting` and asserts both viewers receive it tagged PT 99.
4. **`ScreenShareControlChannelTests`** — viewer→sharer control paths: annotation op over the TCP back-channel reaches `server.onAnnotationReceived`; a viewer PLI is recorded (observed via the test-only `onPLIRecordedForTesting` seam, since no helper is attached to act on the keyframe request).
5. **`ScreenShareRequestToShareTests`** — two raw tsnet nodes: one sends `TailscreenMetadataService.sendRequestToShareAwaitingResponse`, the other's `TailscreenControlListener.onRequestToShare` fires (now with the connection UUID). Also covers the accept/decline round-trip: a `.shareResponse` sent back on the same connection resolves the requester's await to `.accepted`/`.declined`, and silence resolves to `.noAnswer`. No UI/notifications.
6. **`ScreenShareAccessControlTests`** — headless server (`filterData: nil`, `requireApproval` on) + three sequential viewers over local-headscale tsnet: an unknown viewer parks pending and `approveViewer` admits it; pushing an `.allow` policy via `setAccessPolicies` auto-admits a parked viewer once its StableNodeID resolves; pushing `.deny` rejects it (viewer's `onDeniedBySharer` fires via HELLO_DENY) and it never enters the fan-out roster. A second test covers the sharer's one-time kick (`server.disconnectViewer`, the SharingCard viewer-row ✕): an admitted viewer is expelled (its `onDeniedBySharer` fires, roster empties) and the *same node identity* (reused state dir) reconnects to park pending again and gets re-admitted — proving nothing was remembered, unlike "Deny & Block".
7. **`ScreenShareRemoteControlTests`** — headless server (`filterData: nil`) + one admitted viewer over local-headscale tsnet, exercising the opt-in remote-control grant flow: `requestControl` → server `onControlRequestsChanged` surfaces the request; input sent before a grant is dropped by the server gate; `grantControl` (Accessibility check bypassed via `grantBypassesAccessibilityForTesting`) → viewer `onControlGranted` fires; input after the grant passes the gate (`onInputEventForTesting`, no real `CGEventPost`); the viewer's `releaseControl()` clears the server grant (`onControlGrantChanged` → nil) and the viewer gets `onControlRevoked`. A second test covers the "Allow control requests" toggle off: `setAllowControlRequests(false)` → an admitted viewer's request is declined immediately with `.controlRevoked` and never surfaces to `onControlRequestsChanged`. Skipped without `TAILSCREEN_TS_AUTHKEY`.
8. **`PickerHelperSmokeTests`** — verifies the `--picker-helper` `TAILSCREEN_AUTOSHARE_DISPLAY=1` short-circuit (no UI; always runs locally). A second test exercises the full picker-UI lifecycle and SIGTERM path — that one pops the real picker on screen for ~2 s and is **opt-in**: set `TAILSCREEN_RUN_PICKER_LIFECYCLE_TEST=1` to enable.

`AdaptiveBitrateTests` is a pure unit test (no tsnet) covering `TailscaleScreenShareServer.nextAdaptiveBitrate` — the loss/recovery decision math and asymmetric hysteresis extracted from the sweep loop. An E2E version isn't viable: the live sweep intentionally no-ops without a capture-helper attached.

The same extract-the-decision pattern covers the rest of the server's untestable-live machinery, all CI-able: `ViewerLifecycleDecisionTests` (audio-relay SSRC anti-spoof gate, idle-sweep staleness math, PLI ring cap, per-viewer RTP header rewrite, the `shouldEnqueue` per-viewer send-chain drop policy shared by the video and audio chains, the `shouldSendFrame` keyframe-only throttle including its sequence-space-contiguity invariant, and the kicked-viewer quiet window `expelledQuietDecision` — a just-expelled addr's straggler KEEPALIVEs are answered with denial instead of re-run through the admission gate, so a one-time kick can't be silently undone in open-door mode), `PerViewerFairnessDecisionTests` (the per-viewer fairness layer: `lossAttribution` distinguishing one-bad-viewer `.isolated` from everyone-suffering `.widespread` — incl. the ≥2-viewers "no-peers" rule and the exactly-at-threshold boundary — and `fairnessDecision` throttling the isolated viewer to keyframe-only, renewing it while it keeps losing, expiring it after a clean window, and excluding throttled viewers from the global `nextAdaptiveBitrate` input so one bad link can't drag the shared rate), `HelperRestartDecisionTests` (helper exit-reason classification, the 3-in-30s crash budget, the hung-helper watchdog predicate), and `VideoParameterSetExtractionTests` (viewer-side in-band SPS/PPS/VPS extraction), and `ParameterSetExtractionTests` (`ParameterSetExtraction` — the sharer-side inverse, shared by the Linux and Windows libavcodec backends: the H.264 `& 0x1F` vs HEVC `(>> 1) & 0x3F` type masks, all-or-nothing on a partial set, and the crossed-mask cases that would otherwise fail silently — a perfect-looking sharer whose viewers install no parameter sets and see black). `DecodeRecoveryDecisionTests` covers the viewer's consecutive-decode-failure escalation ladder (`VideoDecoder.decodeRecoveryAction`: PLI → session recreate → degraded badge → alert; `>=` thresholds + a per-episode fired-rung latch so each rung fires once even if the counter skips a value), and `ReceiveLoopPolicyTests` the shared UDP receive-loop retry policy (`ReceiveLoopPolicy`: 250 ms → 5 s capped backoff, consecutive + windowed give-up thresholds, and the elapsed-time `readFailed` dead-socket classification) both loops consult instead of dying on the first receive error. `VoiceResilienceDecisionTests` covers the voice-path resilience decisions extracted from `VoiceChannel` (decoder-failure cooldown gate, wrap-aware sequence-gap concealment, adaptive jitter-buffer sizing, clamp-log throttle, single-pass clamp), with the `LossyChannel`-driven end-to-end case (seeded loss/reorder/dup → `receive` → concealment counters) living in `VoiceChannelTests`. `ViewerAccessPolicyTests` covers the viewer-consent logic: the `admissionDecision` gate precedence (blocklist > allowlist > approval gate, incl. the unresolved-identity park when the deny list is non-empty), the `drainDecision` blocklist-aware toggle-off drain, the `connectedDenyList` policy→deny sweep of the connected roster (a "Deny & Block" on an already-connected peer expels it, not just future HELLOs), the `canAcceptPending` pending-cap DoS bound, `AppState.resolvableIntents` (queued "Always Allow"/"Deny & Block" intents persisted on late StableNodeID resolution), the shared `readFailed` dead-socket-vs-timeout classification the request-response wait reuses, the `ViewerAccessPolicyStore` persistence round-trip (injected `UserDefaults` suite), and the tri-state `ViewerApprovalDefaults.load` migration (unset → on, stored choice sticks, `TAILSCREEN_OPEN_DOOR=1` override); `ShareResponseProtocolTests` pins the `.shareResponse` (0x05) wire format — accept/decline round-trip, unknown-type-byte skip (old-peer compat), garbage/wrong-kind payload rejection. `ShareRequestInboxTests` covers the sharer's incoming-ask inbox (`ShareRequestInbox` — the coalescing, cap and expiry lifted out of the AppKit-bound `TailscreenMetadataService` so Linux and Windows get them too): retries coalescing on the requester's **source IP** rather than the hostname it supplies, which is the whole point — a peer picks its own hostname, so keying on it lets one machine stack `maxPending` rows and pin one held-open connection each, and the test constructs exactly that flood; plus the retry keeping the row's identity while taking the fresh connection ID, a full inbox still accepting retries from peers already in it, the split-on-last-colon `sourceKey` that keeps two IPv6 peers apart, and an expiry that ignores a clock that went backwards instead of wrapping into an enormous age and dropping everything. `AnnotationCanvasModelTests` covers the shared canvas state machine (undo stack, remote upsert/idempotence, ephemeral clicks); `ViewerZoomMathTests` covers the viewer's continuous content zoom/pan geometry (`ViewerZoomMath`: cursor-anchored zoom, scale and pan-offset clamping, smart-magnify toggle — extracted from `AspectFitHostView`'s gesture handling); `OverlayModeDecisionTests` covers `AppState.overlayMode(for:)` — the pure `PickerSelection` → sharer-overlay-mode projection (incl. missing-ID fallbacks) used at share start and by the mid-share "Change Source…" flow, which must rebuild the overlay because its mode is immutable. `QualitySettingsTests` covers the quality-settings model (`QualitySettings`: preset→knob mapping, fps/ceiling normalization clamps, helper-env round-trip, `UserDefaults` persistence with decode-with-fallback) and pins the centralized `TransportTuning` / `EncoderTuning` constants to the literals they replaced — including the `clientIdleDisconnectNs == viewerIdleTimeoutNs` invariant. `PeerListFilterTests` covers the peer-list filter — the macOS hub's and, since the same pure types now back `TailscreenHubUI`'s header menu, the GTK and Windows hubs' too (both apps keep their discovery result raw and render a `filteredPeers`-style projection, exactly as `AppState` does; on those hosts the tag axis rides `DiscoveredSharer.tags` and the sharing axis a lazy `TsnetTransport.fetchMetadata` sweep off each discovery) — (`PeerListFilter.matches` — the pure hide-offline ∧ only-sharing ∧ any-of-selected-tags decision with the explicit untagged bucket, which is only consulted while a tag filter is active, and the tri-state sharing input (`PeerSharingState` — deliberately an enum, not `Bool?`) where `.unknown` deliberately hides while the "Only screens being shared" axis is on — the `tag:`-prefix `displayName` stripping, and the `PeerListFilterStore` persistence round-trip via an injected suite incl. the older-blob decode-with-fallback that loads new axes off instead of resetting the filter); the tags themselves ride the netmap both discovery sources already deliver (`IpnState.PeerStatus.Tags` / `Tailcfg.Node.Tags` → `TailscreenPeer.tags`), so there's no probe and no wire change, and `AppState.availablePeers` stays the raw unfiltered list (`filteredPeers` is the projected view) so `TAILSCREEN_AUTOCONNECT_TO` and the filter menu's tag enumeration see every peer. The sharing axis's fetched input is cached in `AppState.peerShareInfo` (populated by the lazy `refreshPeerShareStatus()` sweep over `TailscreenMetadataClient.fetchMetadata`; no-answer removes the entry so it can never go stale-positive), and `ScreenShareProtocolTests` pins the `.metadataRequest`/`.metadataResponse` (0x0B/0x0C) wire pair — round-trips incl. the idle not-sharing answer, the 128-char display-string clamp, garbage-payload-decodes-to-nil without poisoning the stream. `AppCloakTests` covers the Cloaked Apps layer: the pure `AppCloak.effectiveExclusions` decision (`.display`-only, main-toggle-gated, order-stable dedupe — window/app shares never cloak, an explicitly picked app wins), the `AppCloakStore` persistence round-trip (injected suite, tri-state enabled default on, re-add refreshes the display name without duplicating, corrupt blob degrades to empty), and the `PickerSelection.excludedBundleIDs` JSON contract (round-trip, missing-key-decodes-`[]` back-compat, the `settingCaptureAudio`/`settingExcludedBundleIDs` copy helpers preserving each other); the live `SCContentFilter(display:excludingApplications:…)` effect is local-only, and the mid-share re-push rides the `changeSource` path `ScreenShareCaptureHelperTests` already exercises. `ProfileStoreTests` covers the multi-account profile registry (`ProfileStore`/`TailscreenProfile`: first-launch migration onto the legacy `tailscale` state dir, unique `profiles/<uuid>` dirs for added accounts, active-selection persistence via an injected suite, remove-refuses-active/last, corrupt-blob degradation to the default profile, the `tailnetName`/`profilePicURL` missing-key decode defaults that keep pre-field registries loading, `menuTitle`'s tailnet-qualified label — the disambiguator when one login spans several tailnets — and the instance-suffix-at-resolve-time `statePath` contract — a profile is just a tsnet state directory; `AppState.switchProfile` closes the node locally without logging out, so inactive profiles stay signed in on disk) plus the pure `AppState.canSwitchProfile` gate (switching closes the node, so *every* non-idle state — a share still starting, a viewer still connecting — blocks it). `PeerConnectionInfoTests` (now in the portable package, with `PeerRoute` / `ConnectionQualityTier` themselves — all three hubs render this line, and `TailscreenHubUI` cannot import a macOS app target) pins the peer-detail pane's connection decisions (`PeerRoute.from`: a populated `curAddr` outranks a relay because tsnet reports both mid-upgrade, and LocalAPI's empty-string-not-absent convention must not render "DERP ()"; `ConnectionQualityTier.forLatency`: exclusive 60/150 ms bounds, cross-checked against the named constants so a retune can't silently invert the tiers). `LocalizationCatalogTests` enforces the Localization section's "keys byte-for-byte in sync" rule by scanning `L("…")` call sites against `en.lproj/Localizable.strings`; `TimeoutTests`, `ShareLockTests`, `RTPBufferPoolTests`, `AppErrorTests`, and `MenubarIconStateTests` (menubar glyph precedence incl. the pending-request badge and the control-request + waiting-viewer badges on the sharing glyph, control outranking the waiting viewer) pin down the small utilities. `AnnotationRenderingTests` covers displaying viewers' strokes on a sharer with no drawing framework (`ReceivedAnnotations`: the drag upsert that must not stack one stroke into hundreds, unknown-undo as a non-change, click-marker expiry leaving other tools alone, an undone ephemeral not leaving its deadline behind; `AnnotationRasterizer`: premultiplied alpha — getting it wrong is a dark halo rather than an error — coverage-based antialiasing, off-screen clipping, and draw order); `CaptureTimingsTests` covers the sharer-side "which stage is slow" split (`CaptureTimings`/`CaptureTimingAccumulator`: per-window averages with acquire averaged over every pass but convert/encode over encoded frames only — a still screen must not read as a fast sharer — the window reset, the zero-frame no-divide, and `slowestStage` naming the one to fix); `WindowsCaptureRegionTests` covers the Windows sharer's where-is-the-target problem (`WindowsCaptureRegion.resolve`: a WGC `GraphicsCaptureItem` carries no HMONITOR, so its SIZE is matched against the enumerated monitors — unique match resolves, a window-sized item is `.notADisplay`, and **two identical monitors decline** rather than guessing, since a click landing on a screen the viewer can't see is worse than no click; the failures carry sharer-facing reasons so a missing Request Control isn't a mystery). `WindowsPointerMappingTests` covers the Windows half of the same problem (`WindowsPointerMapping`: normalized → screen → `SendInput`'s 0…65535 virtual-desktop absolutes — the `65535/(extent-1)` scale factor that makes the last pixel column reachable, negative `SM_XVIRTUALSCREEN` origins from a monitor left of the primary, clamping instead of wrapping outside the desktop, and `WHEEL_DELTA` saturation in a signed 16-bit field), and `SendInputInjectorTests` the injector's decisions (revoke TOCTOU — an event queued before `deactivate()` never lands after it; the synthesized button-up so a revoke mid-drag can't strand a held button; modifiers pressed around each key and released in reverse, since Windows has no per-event modifier field the way `CGEvent` does; Caps Lock never synthesized because it is a toggle; unmappable HID usages dropped rather than guessed; the extended-key bit that distinguishes Right Arrow from numpad 6) — all through the `onInjectForTesting` seam and an injectable `virtualDesktopProvider`, so they run on Linux CI with no real `SendInput` and no cursor moved. `RemoteControlMappingTests` covers the opt-in remote-control coordinate mapping (`RemoteControlMapping.globalPoint`: normalized `[0,1]` → global-Quartz per share kind, non-zero + negative (multi-display) origins, out-of-range clamping; `boundingRect` app-window union; and `captureRect`'s per-kind branch selection via injected resolvers — crucially that an **application** share clamps to the union of the app's window rects, NOT the whole display, so a granted viewer can't click the menu bar/Dock/other apps) and `RemoteControlPolicyTests` the grant/flood decisions (`RemoteControlPolicy.shouldInject` connectionID gate incl. nil-grant deny, `coalesceMouseMoves` consecutive-move collapse that never drops button/scroll/key events, `EventRateLimiter` sliding-window ceiling + no-record-over-budget recovery); `RemoteControlInjectorTests` covers the injector's revoke gate (input dropped once `deactivate()` seals it — the post-revoke TOCTOU fix), the stuck-button release (a button held at revoke gets a synthesized button-up, incl. middle), and the neutral-wire → CGEvent translation (`eventFlags` per-bit + unknown-wire-bits-ignored, HID→kVK key translation, unmappable-HID-usage dropped, modified clicks/scrolls carrying their translated flags to injection), all via the `onInjectForTesting` seam so no real `CGEventPost` warps the CI cursor; `MacKeyCodeMappingTests` pins the kVK↔HID table (bijectivity — mac→mac must reproduce the exact keycode — spot rows, fn/Insert unmappable) and the viewer-side `keyModifiers(from:)` capture mapping; `GlobalHotkeyTests` pins `handlerShouldFire` (the Carbon id-dispatch filter that stops one hotkey's handler swallowing another's — the regression where registering the revoke hotkey killed the mic toggle). The `.controlRequest`/`.controlGranted`/`.controlRevoked`/`.inputEvent`/`.controlReleased` wire round-trips, the revoke-reason clamp, the malformed-`.inputEvent`-decodes-to-nil case, and the oversized-frame-length DoS guard (`ScreenShareMessage.maxPayloadLength` → `ScreenShareMessageParser.isCorrupt`, inclusive boundary) are pinned in `ScreenShareProtocolTests`, and the live grant flow (request → server surfaces it → grant → viewer `onControlGranted` → gated input admitted, pre-grant input dropped → viewer `.controlReleased` clears the server grant + viewer `onControlRevoked`) rides local-only tsnet in `ScreenShareRemoteControlTests` (below); real `CGEvent` injection needs Accessibility TCC and is manual/local-only. `ColorInfoTests` covers the wide-gamut / 10-bit / HDR color model (`ColorInfo`: display-capability → color-space selection wide-gamut→P3 / HDR+10-bit→BT.2020 PQ / else BT.709, the VideoToolbox CFString-key + `CGColorSpace`-name mappings, `profileLevel` HEVC Main-vs-Main10 selection, `capturePixelFormat` 8-vs-10-bit, `captureColorSpaceName` overriding only non-709, renderer-side `layerColorSpaceName(forPrimaries:)`, `downgradedTo8Bit`, Codable round-trip) plus `VideoEncoder.sessionAttempts` — the Main10 → HEVC-8-bit → H.264 fallback-ladder ordering; the color/bit-depth ride the SPS VUI in-band (no wire change), the only new byte being the optional PROFILE_NO (0x09) 8-bit-fallback control message (round-trip pinned by `RTPPacketTests`), and the live capture→encode→decode→render path is local-only (`ScreenShareCaptureHelperTests` can assert the encoded SPS primaries/depth; EDR rendering is visual-check-only). `SystemAudioFramerTests` covers the helper-side 960-sample framer (`SystemAudioFramer`: exact boundary, remainder carry, multi-frame drain, order preservation) and `SystemAudioRoutingTests` the viewer-side demux (`VoiceChannel.audioRoute` PT→route decision, plus an in-process `receive` that proves a real PT-99 packet fires `onSystemAudioPCM` and never `onMixedPCM`); `RTPAudioTests` and `CaptureHelperWireTests` also gained system-audio cases (PT-99/SSRC-1 packetizer, depacketizer accepting 98/99 while still rejecting 96/97, the `audioAccessUnit`/`setAudioEnabled` frame round-trips, and the `PickerSelection.captureAudio` field's backward-compatible decode). The **loss-recovery** layer (NACK selective retransmission + receiver-feedback congestion control) is covered by four CI-able pure suites: `LossRecoveryWireTests` (in `RTPPacketTests.swift`: NACK/RR/PING round trips, the `ScreenShareCaps` extended-HELLO/HELLO_ACK handshake, and the legacy-5-byte-`decodeHelloAck`-rejects-6-byte back-compat contract), `NACKSchedulerTests` (the viewer's `NACKScheduler`: reorder tolerance so pure reordering never NACKs, the RTT-keyed re-NACK cadence, PLI fallback on ring-age / attempt exhaustion, and `packFCI`), `RetransmitBufferTests` (the send-side `RetransmitBuffer`: wrap-safe seq→template lookup, the triple age/bytes/count eviction, and the pure token-bucket `retransmitDecision` budget), and `CongestionDecisionTests` (`nextCongestionDecision`: the RR-loss-fraction cut/hold/raise bands, NACK-vs-PLI weighting, the 60→30→15 fps-ladder transitions with hysteresis, legacy-PLI-input parity so `AdaptiveBitrateTests` stay valid unchanged, the fps-recovery clamp to the session cap, `congestionInputs` isolating an RR-lossy-but-PLI-quiet viewer instead of letting it set the global rate, and recovery not being blocked by served NACKs). The scheduler/ring cases cover the FCI datagram cap (`fciCappedSeqs`), the >maxGaps discontinuity → PLI fallback, the NACK→retransmit RTT self-measurement, and `RetransmitBuffer.has()` agreeing with `template()` after batch eviction. `WireByteRegistryTests` is the single source of truth for **every wire constant**, pinned per channel (TCP message types + framing constants, UDP control bytes + `ScreenShareCaps` bits, helper-wire `OutType`/`InType`, the picker framing by writer→reader round-trip, RTP payload types + reserved SSRC ordering, the `KeyModifiers` wire bits) with exactness/exhaustiveness (`CaseIterable`)/per-channel-uniqueness legs and failure messages that name both claimants — add a registry row whenever you add a wire byte, and never renumber a shipped one. `ParserFuzzTests` is the deterministic seeded byte-level fuzz harness (random bytes / truncations / bit-flips / length-field mutations × the framed TCP parser, RTP depacketizers + `RTPHeader.decode`, UDP control decoders, `AudioRTPDepacketizer`, and `HelperScreenCapture.decodeParameterSets` incl. re-based `Data` slices); seeds derive from loop indices and are printed on failure, and `SoakTests` (env-gated on `TAILSCREEN_SOAK=1`, nightly workflow) reruns the same `ParserFuzzHarness` at ~50× plus a seeded `LossyChannel` impairment matrix. `RRAccountingTests` covers `RRAccounting` — the viewer's receiver-report bookkeeping extracted from the client, fixing the baseline off-by-one and duplicate-inflation defects (first arrivals only, via a 4096-bit sliding dedupe window sized to the retransmit horizon; a served NACK retransmit still counts as received). `NACKSchedulerTests` also pins the 65535→0 wraparound block (gap across the wrap NACKed, straggler fills + feeds RTT, >maxGaps discontinuity across the wrap → PLI, and packFCI's current not-wrap-aware two-group split — an efficiency wart pinned so a future fix can't silently drop coverage). `ScreenShareProtocolTests` additionally pins the NaN/Infinity/`1e999`-rejecting `.throw` decoder default on `.inputEvent` payloads, with the NaN-safe `RemoteControlMapping.globalPoint` clamp (non-finite → 0) in `RemoteControlMappingTests` as defense-in-depth; `RemoteControlPolicyTests` gained the per-IP control-request notification dedupe (`AppState.controlRequestNotificationDecision`) and the `RemoteControlDefaults` round-trip. The **FEC layer** (XOR single-parity, phase 2 of loss recovery) adds three more pure suites: `FECCodecTests` (parity/recover round trips for every group position incl. the marker packet, mixed lengths, HEVC, seq wrap-around, `groupRanges` **balanced** packing — ⌈count/N⌉ equal-sized groups so the marker packet is always covered (no sub-`minGroupSize` remainder), plus the ≤16 clamp, malformed-body/member rejection — recovery never emits a torn packet), `FECGroupBufferTests` (single loss solved on parity arrival, parity-before-member reordering, ≥2-loss parity aging out to NACK, fully-received parity dropped, the at-most-once late-original guard, and the bounded media ring never mis-solving after eviction), and `FECOverheadDecisionTests` (`fecSweepDecision`: the strictly PER-VIEWER RTT ∧ loss gate with exclusive boundaries — cross-viewer worst-RTT/worst-loss mixing must never turn FEC on with nobody gated, and encoder compensation follows the gated set, never a held N — the 10/7/5 raw-loss ladder over the gated viewers, raw-loss reconstruction from residual + `fecRecovered` + `nackRecovered` against each viewer's OWN expected packet count (multi-viewer recoveries don't inflate; a throttled viewer's small denominator keeps its gate stable; a NACK-masked-but-high-raw-loss viewer at high RTT still gates on) — the anti-oscillation case where FEC hiding all loss stays on — the two-clean-window off-hysteresis, legacy-viewer invisibility, and the N/(N+1) `fecCompensatedBitrate` with its scaled-floor clamp); `NACKSchedulerTests` additionally pins `cancelGap` (clears without an RTT sample or PLI), `noteRecovered` (advancing past a recovered tail-of-batch/marker seq so the next batch opens no phantom gap, while genuinely skipped seqs still open gaps), `setReorderTolerances` (in-place FEC arm/disarm preserving gaps + RTT estimate), and the FEC-mode N+2/25 ms tolerances, and `RTPPacketTests` the 0x0D codec (round trip incl. max-size body, truncated/garbage/oversized → nil, count bounds) plus the 20/22/24-byte RR both-lengths compat (the 24-byte form carries `fecRecovered` + `nackRecovered`) and the `NACKScheduler` served-retransmit recovery counter (`drainNackRecovered`, distinguishing a NACKed-then-filled gap from pure reordering). The closed loop additionally pins per-group parity INTERLEAVING (early-group loss in a multi-group keyframe recovered with zero NACKs) and the covered-marker-loss case (recovered final packet leaves no phantom gap). `CaptureStopDecisionTests` covers `AppState.captureStopAction` — the capture-failure routing (`userInitiated` / `connectionLost` / `helperUnrecoverable` / `sourceClosed` / `attemptRestart`): a non-retryable helper exit tears the share down instead of looping `restartCapture()` against a source that will never come back, split by `classifyHelperExit` into a genuine error (`.slotRefused` / `.permanent` → `helperUnrecoverableErrorDomain` → error alert) vs. the *expected* shared-window/display/app close (the helper's `writeFatal("source-gone: …")` on a `PickerReconstructionError` → `.sourceGone` → `helperSourceGoneErrorDomain` → `.sourceClosed` → a gentle `presentNotice`, not an error). Only the terminal domains (those two plus `receiveLoopErrorDomain`) stop outright; everything else still gets one fresh-budget restart. The mid-share source close is caught either by the SCStream delegate `didStopWithError` or an in-band `SCFrameStatus.stopped` frame (`ScreenCapture`'s stop bridge, gated by `beginStopping()` so a deliberate `stop()`/changeSource helper swap isn't mistaken for a window vanish), both flowing to the same respawn → `windowNotFound` → `source-gone` teardown. When you extract a new pure decision from an async loop for testing, add it to this list.

Test-only seams added for the above: `TailscaleScreenShareClient.onDecodedFrameForTesting`, `.sendPLIForTesting()`, `.extractParameterSets` (internal, not private); `TailscaleScreenShareServer.onPLIRecordedForTesting`, `.onNACKServedForTesting`, `.injectSyntheticParameters`, `.broadcastForTesting`, `.broadcastSystemAudioForTesting`, `.nextAdaptiveBitrate`, `.nextCongestionDecision`, `.rewriteRTPHeader` (internal, not private), plus the pure static decision funcs (`audioRelayDecision`, `admissionDecision`, `drainDecision`, `connectedDenyList`, `canAcceptPending`, `lossAttribution`, `fairnessDecision`, `shouldEnqueue`, `shouldSendFrame`, `staleAddrs`, `expelledQuietDecision`, `appendingPLI`, `helperLooksHung`, `classifyHelperExit`, `slidingWindowCrashCount`, `lowerFpsTier`/`raiseFpsTier` (fps ladder, the raise clamped to the session cap), `rrLossPLIEquivalent` + `congestionInputs` (folding RR loss through the same isolation gate as PLI so one viewer's RR loss can't set the global rate), the standalone `NACKScheduler` / `RetransmitBuffer` / `FECCodec` / `FECGroupBuffer` types incl. `RetransmitBuffer.retransmitDecision`, `NACKScheduler.packFCI` / `fciCappedSeqs` (bounding the emitted NACK to one datagram) / `cancelGap` (gap clear without an RTT sample) / `noteRecovered` (recovery-aware cursor advance) / `setReorderTolerances` (in-place FEC arm/disarm) + `defaultReorderToleranceNs`/`defaultReorderPacketTolerance`, the server's FEC arm (`fecSweepDecision` + `FECViewerSample`/`FECSweepDecision`, `fecViewerGate`, `fecRecoveredQ8`, `fecCompensatedBitrate`) plus its `onFECParitySentForTesting` seam beside `onNACKServedForTesting`, and `VoiceChannel`'s `audioRoute` / `decoderGateAction` / `gapAction` / `jitterBufferTarget` / `shouldLogClamp` / `clampToUnitRange` / `staleSSRCs` / `concealmentEmitCount` / `concealmentFadeOut` / `isStarveResume` / `isPauseDeviation`); `AppState.overlayMode(for:)` (internal, not private — the pure selection→overlay-mode projection `OverlayModeDecisionTests` covers); `VideoEncoder.sessionAttempts` (internal — the pure color/bit-depth fallback ladder) and `ColorInfo`'s pure mappings (`forDisplay`, `profileLevel`, `capturePixelFormat`, `captureColorSpaceName`, `layerColorSpaceName`, `downgradedTo8Bit`); `TailscaleScreenShareClient.sendBitDepthFallbackRequest()` (drives the PROFILE_NO path); `VoiceChannel` also exposes DEBUG-only `decoderFailuresForTesting` / `injectDecoderFailureForTesting`. Remote control adds `TailscaleScreenShareServer.onInputEventForTesting` (fires with each gate-admitted input event, before injection) and `.grantBypassesAccessibilityForTesting` (skip the Accessibility-TCC precondition so an E2E test can exercise the grant gate headlessly — the injector no-ops with `filterData: nil`); `RemoteControlInjector.onInjectForTesting` + `.drainSyncForTesting()` (observe the injected-action stream and drain the serial queue deterministically, with no real `CGEventPost`) plus the pure `.eventFlags` (neutral `KeyModifiers` → `CGEventFlags`, constructive so nothing wire-supplied lands unmasked) and the `activate`/`deactivate` gate; `MacKeyCodeMapping` (the bijective kVK↔HID table both endpoints translate through); `GlobalHotkey.handlerShouldFire` (the pure id-dispatch filter) and `.signature`; `RemoteControlInputView.keyModifiers(from:)` (nonisolated); `RemoteControlMapping.boundingRect` + `captureRect`'s injectable `displayBounds`/`windowBounds`/`appWindowBounds` resolvers; `ScreenShareMessageParser.isCorrupt` + `ScreenShareMessage.maxPayloadLength` (the frame-length DoS guard); plus the pure `RemoteControlPolicy.shouldInject` / `coalesceMouseMoves`, `EventRateLimiter`, and `RemoteControlMapping.globalPoint`. This iteration adds `HelperScreenCapture.decodeParameterSets` (internal static, slice-safe), `PickerHelperFraming.writeFramedPayload` + `PickerHelperClient.readFramed` (internal — the picker framing round-trip seam), `RTPHeader.firstViewerSSRC` / `.sharerVoiceSSRC` (the extracted reserved-SSRC constants) and `RTPHeader.allPayloadTypes` / `ScreenShareCaps.allKnown` (production-side lists the registry cross-checks — append new PTs/caps there), `RRAccounting` (the pure receiver-report bookkeeping struct), `ParserFuzzHarness` (in `Apps/macOS/Tests/`, budget-scalable fuzz engine shared with `SoakTests`), `AppState.controlRequestNotificationDecision` + `.isStaleGrantNotification` (nonisolated statics), `TailscaleScreenShareServer.setAllowControlRequests` (which also declines-and-drains parked requests when turned off) and `.recordControlRequestForTesting`; the server's `onControlGrantChanged` now passes a monotonic `(generation, snapshot)` pair so MainActor-hopping consumers can drop out-of-order deliveries. Shared bring-up helpers live in `TailscreenE2EHelpers.swift` (`encodeSyntheticAUs`, multi-dir `makeStateDirs`, and the capture-test quartet `skipCaptureTestOnCI` / `overrideHelperExecutable` / `mainDisplayFilterData` / `startCursorJiggle`).

```bash
make test-e2e-local     # XCTest suites above, under local headscale
make test-e2e-harness   # two real Tailscreen processes, asserted by log marker
```

**Linux sharer → Linux viewer** (`scripts/e2e-linux-sharer.sh`, local-only): the
non-macOS counterpart. Brings up local headscale + an Xvfb display with real
content, runs `tailscreen-sharer-linux` (the portable `TailscaleScreenShareServer`
+ the X11 `CaptureEncoding` backend) and `tailscreen-viewer-probe` (the real
receive path with a counting sink instead of a window), and asserts the viewer
was admitted, decoded frames at the display's geometry, and that those frames
are **non-uniform** — i.e. real captured pixels rather than a flat rectangle
that a frame-count assertion alone would accept. It also incidentally pins the
conditional-capability behaviour: with no injector supplied the advertised
`serverCaps` omits `.remoteControl`.

Env-var test affordances:

| Env var | Read by | Effect |
|---------|---------|--------|
| `TAILSCREEN_OPEN_DOOR=1` | Main process (`ViewerApprovalDefaults.load`) | Force the require-approval gate off regardless of the stored preference. Viewer approval defaults **on**, so the scripted harness and `test-local.sh` set this to keep automated viewers from parking on the approval prompt. Never set in production. |
| `TAILSCREEN_AUTOSHARE_DISPLAY=1` | `--picker-helper` subprocess | Skip the interactive picker; emit a synthetic main-display `PickerSelection` and exit. |
| `TAILSCREEN_AUTOSTART_SHARE=1` | Main process (`AppState.init`) | Once signed in, automatically invoke `presentNativePicker()`. Pair with `TAILSCREEN_AUTOSHARE_DISPLAY=1`. |
| `TAILSCREEN_AUTOCONNECT_TO=<prefix>` | Main process (`AppState.init`) | Once signed in, discover peers and connect to the first one whose hostname starts with `<prefix>`. |
| `TAILSCREEN_HELPER_EXE=<path>` | `HelperScreenCapture` / `PickerHelperClient` | Override `Bundle.main.executableURL` for helper spawns. Only used by XCTests (under xctest, `Bundle.main` points at the test harness, not Tailscreen). |
| `TAILSCREEN_SOAK=1` | `SoakTests` | Opt in to the nightly long-run soak tier (ParserFuzz at ~50× budget + the seeded LossyChannel impairment matrix). Off for `make test` and PR CI; `.github/workflows/soak.yml` sets it. |
| `TAILSCREEN_RUN_PICKER_LIFECYCLE_TEST=1` | `PickerHelperSmokeTests` | Opt in to the picker-UI lifecycle test that pops the real picker on screen for ~2 s before SIGTERM. Skipped by default to keep `make test-e2e-local` non-interactive. |
| `TAILSCREEN_DEBUG_FEC=1` | Server (`TailscaleScreenShareServer`) + viewer (`TailscaleScreenShareClient`) | Log the FEC-arming feedback loop: the server prints per-viewer FEC sweep inputs (measured RTT, residual/raw loss, recovered/expected, `.fec` cap) and the arm decision every 5 s; the viewer prints each receiver-report send (fracLost, whether a PING was echoed, delay). Diagnoses why FEC did/didn't gate on under real loss (e.g. RTT staying 0 ⇒ RRs/ping echoes aren't landing so the >150 ms gate can't trip). Off by default; diagnostic only. |

The harness greps the merged log for `E2E_MARKER firstFrame width=… height=…`, emitted from `AppState`'s viewer-side `onVideoSizeChanged` callback on the first decoded frame.

### Local manual testing — multiple instances on one Mac

```bash
./test-local.sh           # 2 instances (default)
./test-local.sh 3         # N instances
```

Each child gets `TAILSCREEN_INSTANCE=<i>`, which suffixes the Tailscale state directory and hostname (e.g. `wisp-1`, `wisp-2`). Without it, two processes share `~/Library/Application Support/Tailscreen/tailscale`, reuse the same machine key, and the browser sees zero peers (it's looking at its own node).

Merged stdout/stderr lands in `/tmp/tailscreen-merged.log` (override with `TAILSCREEN_LOG`). Ctrl-C kills the whole process group.

Memory-debug modes (set before invoking the script):

| Env var | Effect |
|---------|--------|
| `TAILSCREEN_DEBUG_ZOMBIES=1` | `NSZombieEnabled` + malloc stack logging — over-releases log instead of crashing |
| `TAILSCREEN_DEBUG_ASAN=1` | Sets `ASAN_OPTIONS`; **also rebuild with** `swift build -Xswiftc -sanitize=address` |
| `TAILSCREEN_DEBUG_GMALLOC=1` | libgmalloc — known to break ScreenCaptureKit's XPC; prefer Instruments' Zombies template |

### Simulating a bad network on one Mac — `scripts/net-impair.sh`

Loopback and local-headscale deliver packets with ~0% loss, in order, at a
16 KB MTU. That hides every WAN-only failure mode: loss-driven PLI/keyframe
storms, the adaptive-bitrate sweep, viewer stall + recovery, and one-slow-
viewer head-of-line blocking. `scripts/net-impair.sh` uses pf + dummynet (the
machinery behind Network Link Conditioner) to beat up the node-to-node UDP
transport so those paths actually run.

```bash
sudo ./scripts/net-impair.sh up --loss 3 --delay 80   # 3% loss, 80 ms each way
./test-local.sh 2                                      # share + view, watch it cope
sudo ./scripts/net-impair.sh down                      # always tear down when done
sudo ./scripts/net-impair.sh status                    # inspect active pipes/anchor
```

Knobs: `--loss PCT`, `--delay MS`, `--bw RATE` (e.g. `5Mbit/s`), `--reorder PCT`
(+`--reorder-delay MS`), `--iface IFACE` (default `lo0` — two co-located tsnet
nodes prefer their loopback endpoints). It impairs UDP on the interface while
leaving headscale control (8080/tcp) and STUN (3478/udp) alone so setup still
works.

Caveats: it's **best-effort** — if the two nodes fall back to a DERP-relayed
path the flow may not be on `lo0` (confirm impairment is biting via the
viewer's rising PLI count / dropping bitrate in the stats overlay; otherwise
try `--iface en0`). dummynet has no native packet-reorder knob, so `--reorder`
uses the two-pipe + `probability` workaround and may be rejected on some macOS
pf versions. For **deterministic, root-free, CI-able** reorder/loss/duplicate
coverage of the depacketizer, use the unit tests in `RTPPacketTests` and the
end-to-end pipeline tests in `RTPLossyChannelTests` (via `LossyChannel`)
instead —
the harness is the end-to-end complement, not a replacement.

## Portable protocol core (TailscreenKit)

The wire protocol + pure decision logic (RTP/framing/control codecs, NACK/
retransmit/FEC/RR loss recovery, policy/tuning types — 30 files, Foundation +
`Synchronization` only) lives in a standalone SwiftPM package that builds
**on Linux**: `TailscreenKit`. The app consumes it as a real
dependency — the files exist only in the package, and
`Apps/macOS/Sources/ProtocolReexports.swift` `@_exported import`s the products so app
code uses the types unqualified. Everything the app touches is `public`
(incl. explicit memberwise inits); test-only seams stay `internal` and the
test suite reaches them via `@testable import TailscreenProtocol` /
`TailscreenTransport` / `TailscreenAudio` / `TailscreenSharer`. CI's `linux-protocol` job (and
`make test-protocol` locally, macOS or Linux) enforces the boundary.

The package has a second tier: target **`TailscreenTransport`**
(`TailscalePeerDiscovery` + `TailscaleIPNWatcher` + `TailscaleAuth`, whose
browser-open step is host-supplied via `onOpenAuthURL`), which depends on
`TailscreenProtocol` and the patched `TailscaleKit`. Compiling it needs the
submodule + patches (header only, no Go build — `make test-protocol`
handles this), and its Combine surface (`ObservableObject`/`@Published`,
which mac Foundation re-exports) compiles on Linux via
`PortabilityShims.swift` — whose `Published` shim provides a
`$prop.values`-compatible AsyncStream because `TailscalePeerDiscovery`
consumes `watcher.$peers.values`.

And a third tier: target **`TailscreenAudio`** (`OpusVoiceEncoder` /
`OpusVoiceDecoder` / `OpusPCM` — the Opus codec wrapper + Float32↔Int16 /
960-sample framing over `OpusKit`/libopus, `@_exported`ing OpusKit so
`Opus.Application` is visible). Foundation + OpusKit only — it also builds
on Linux, so a future non-macOS client reuses the exact codec while
supplying its own platform audio I/O (`VoiceChannel`/`SystemAudioTap` are
the mac-side consumers). It's kept out of `TailscreenProtocol` so that tier
stays dependency-free; the `linux-protocol` job installs `libopus-dev` +
`pkg-config` for it (opus.pc is on Linux's default pkg-config path).

And a fourth tier: target **`TailscreenViewer`** (`ViewerSession` + the
`VideoDecoding` / `VideoSink` / `AudioSink` protocols and the
`DecodedVideoFrame` value type, plus `ViewerPipeline` — the host-supplied-
factory assembler that wires a decoder + sinks into a session — and
`FrameStore`, the lock + value-type-COW frame hand-off any renderer backend
polls from its UI thread, plus the two pieces every GUI host needs between the
session and its device: `ThreadedAudioSink`, which turns a backend's blocking
`play` into a non-blocking enqueue drained on one thread — mandatory when the
transport is serviced by the UI thread, as it is in both the GTK and WinUI
viewers — and `MonoPCMConverter`, the 48 kHz mono → device-(rate, channels)
Float32 adaptation with a buffer-boundary-continuous linear resampler.
`I420Converter` (limited-range BT.709 I420 → BGRA8, for CPU-blit renderers) sits
alongside them for the same reason: pure arithmetic every backend needs and no
backend can test, so it lives where Linux CI runs it, and `FrameRateCounter` — the
stats HUD's ~1 s fps window — joined them when the Windows viewer needed the
same counting the GTK sink had inline; extracting it is what surfaced that its
`0` window-start sentinel collides with a legitimate timestamp). This is the portable,
host-agnostic viewer
data-plane core: it turns inbound RTP datagrams + a host-supplied clock into
decoded video frames, decoded audio, and outbound feedback control bytes
(HELLO / NACK / PLI / receiver reports), reusing `TailscreenProtocol`
(`MultiCodecDepacketizer`, `NACKScheduler`, `RRAccounting`,
`AudioRTPDepacketizer`, `ScreenShareControlMessage`) and `TailscreenAudio`
(`OpusVoiceDecoder`). It owns **no** socket, thread, or timer — the host feeds
it bytes (`receiveRTP`) and a clock (`tick(nowNs:)`) and ships its outputs — so
it's fully unit-testable and portable, and it stays free of any concrete
codec/renderer/audio backend (FFmpeg decode / GTK-GL render / ALSA audio plug in
behind the protocols in the Linux viewer). Depends on `TailscreenProtocol` + `TailscreenAudio` only, so it also
builds on Linux; the video path + audio path + HELLO/PLI/NACK/RR handshake +
**FEC ingest** are covered. FEC ingest mirrors the mac client: `FECGroupBuffer`
+ `FECCodec.recover` arm on the first `0x0D` parity datagram, recovered packets
feed the shared ingest path (RR counts them received, `NACKScheduler.noteRecovered`
clears the gap without an RTT sample), NACK tolerances loosen in place while
parity flows and disarm after `TransportTuning.fecParityIdleNs`, and the RR's
`fecRecovered` field carries the raw-loss signal. `ViewerSession.ingestVideo`
now drains all ready AUs after each ingest (`MultiCodecDepacketizer.drainReady`)
so a gap fill — reorder completion or an FEC-recovered tail packet with no
trailing traffic — surfaces every unblocked frame immediately. Tests:
`TailscreenViewerTests`.

And a fifth tier: target **`TailscreenSharer`** — the host-agnostic *sharer*
data plane, i.e. `TailscaleScreenShareServer` itself. Despite being the
biggest file in the repo and reading as deeply macOS-bound, it turned out to
contain exactly **two** genuine Apple API usages (an `NSImage` preview
callback and one `SCStreamError`); the rest was portable logic — viewer
admission + the access-policy gate, RTP fan-out, NACK/retransmit/FEC, the
congestion and per-viewer fairness controllers, the idle sweep, the
capture-restart budget + hung-backend watchdog, the remote-control grant
gate — that merely lived in a mac target. Moving it needed no redesign: the
`os` locks became `Synchronization.Mutex`, the preview callback became
opaque `Data` (the host decodes at the point of display), and the
`SCStreamError.userStopped` signal became
`TailscaleScreenShareServer.userStoppedErrorDomain`.

The platform surface is two protocols in `SharerBackends.swift`:
**`CaptureEncoding`** (capture + encode — callbacks for access units /
parameter sets / system audio / preview / exit, commands for
`requestKeyframe` / `setBitrate` / `setFrameInterval` / `setAudioEnabled`)
and **`InputInjecting`** (remote-control injection). `CaptureEncoding` is
deliberately shaped like `CaptureHelperWire`'s `OutType`/`InType`: the seam
already existed as an IPC wire and had simply never been named as a
portability boundary, which is why `HelperScreenCapture` and
`RemoteControlInjector` conform with *empty* extensions
(`Apps/macOS/Sources/ScreenShareBackends.swift`). The server takes a capture
**factory**, not an instance, because macOS restart semantics require a
brand-new helper process each time. One behaviour genuinely changed:
`ScreenShareCaps.remoteControl` is now advertised **iff** the host supplied
an `InputInjecting` backend — the mac-only server could hard-code "this
platform can inject" and a portable one can't, so a host without injection
correctly withholds the bit instead of inviting requests it can't serve.

And a sixth tier: target **`TailscreenViewerTsnet`** — the viewer's tsnet
transport (`TsnetTransport` + `ViewerBackChannel`): node bring-up including
the interactive browser-login URL off the IPN bus, peer discovery, the UDP
media socket, the TCP back-channel, and the run loop that drives
`ViewerPipeline`. It lived in `Packages/TailscreenLinuxBackends` until the Windows app needed it;
nothing in it was ever Linux-specific, and the `import TailscreenViewerCore`
that tied it to FFmpeg and ALSA referenced **no symbol** from that module.
Consuming the transport therefore no longer means also acquiring a video
decoder and an audio backend a host may implement differently — which is the
whole point on Windows, where neither FFmpeg nor ALSA applies. Like
`TailscreenTransport` it needs only the patched libtailscale **header** to
compile; `libtailscale.a` is a link-time input, so the `-L` flag belongs on
the executable that links it. `@MainActor`-isolated: both GUI hosts service
its recv/send/tick loop on the main thread.

The rules for package files (no Apple frameworks; how to move a file in;
what must be `public`) live canonically in
**`Packages/TailscreenKit/README.md`** — read it before touching the
package. The package's `TailscreenProtocolTests` target now carries the
migrated pure suites — the loss-recovery/RTP/wire/util tests whose subject
types live entirely in `TailscreenProtocol`/`TailscreenAudio`
(`FECCodecTests`, `FECGroupBufferTests`, `NACKSchedulerTests`,
`RetransmitBufferTests`, `RRAccountingTests`, `RTPPacketTests`,
`RTPBufferPoolTests`, `RTPAudioTests`, `ReceiveLoopPolicyTests`,
`CaptureHelperWireTests`, `ScreenShareProtocolTests`,
`ShareResponseProtocolTests`, `ShareLockTests`, `QualitySettingsTests`,
`TailscreenInstanceTests`, `ViewerZoomMathTests`, `OpusAudioCodecTests`,
`AccountProfileStoreTests`, `SharerNoticeTests`, `ShortcutCatalogTests`,
`AnnotationGeometryTests` — the latter covering `AnnotationGeometry`, the
**shared** derivation of a stroke's outline from its stored anchor+current
points (rectangle corners, ellipse arc, arrowhead barbs, click ring). It lives
in the portable tier on purpose: both endpoints render each other's relayed
strokes, so the constants (`arrowHeadLength` = mac's `max(12, width*4)`,
`arrowHeadAngle` = ±150°, the `ClickMarker` radii) must agree or the same
`.arrow` looks different depending on who drew it. The Linux/GTK viewer
consumes it today; the macOS overlay still has its own inline copy of the same
formulas, and adopting this one is a queued follow-up),
plus `SharerNoticeTests` (`SharerNoticeDecision` — *when* to interrupt the
sharer, and about whom. Forget-on-leave over whole-list snapshots: an identity
absent from the current snapshot is pruned so a peer that genuinely asks again
is announced again, while a snapshot re-emitted for an unrelated reason — a
hostname resolving off the netmap, another row changing — announces nothing.
`identity` stays an opaque string because the callers legitimately want
different keys: IP for control requests (a redialing peer mints a fresh
connection id and would notify on each), `ip:port` for the roster (a real
rejoin *should* ping). Portable because macOS grew **three** ad-hoc mechanisms
for one decision — `notifiedViewerIDs`, `controlRequestNotificationDecision`,
and a bare snapshot diff in `handlePendingViewersChanged` — and Linux/Windows
have none; also pins that `blocksSomeone` (which drives each platform's
break-through-Focus level) implies actionable, and that `dismiss` is never an
offered button, since closing a banner must not read as a decision about a
peer),
`ShortcutCatalogTests` (`ShortcutCatalog` — every keyboard shortcut as data,
rendered natively per host: menu items + the ⌘? sheet on macOS,
`GtkShortcutsWindow` on Linux, `KeyboardAccelerator` on Windows. Modifiers are
named by ROLE — `primary` is ⌘ on macOS and Ctrl elsewhere — which is
deliberately *not* `KeyModifiers`: that type is the remote-control wire model
and names physical keys because it replays keystrokes on another machine, where
the same physical key is what must survive; this one names intent, which is a
different physical key per platform. `collisions(_:)` is checked per display
style because `primary` and `control` are distinct on macOS and both collapse
to Ctrl elsewhere, so a pair that reads fine in the menu bar can silently
become one chord on GTK/WinUI — a third test constructs a clash so the detector
can't pass by always returning empty),
plus `ViewerApprovalPreferenceTests` (`ViewerApprovalPreference` — the
"Require approval for new viewers" value the GTK and Windows apps push into
`setRequireApproval`: default-on, the tri-state `object(forKey:)` migration
that tells a never-touched install from an explicit opt-out, the
exactly-`"1"` `TAILSCREEN_OPEN_DOOR` override, and that the override never
clobbers the stored choice. Portable because the server's own gate defaults
**off** — right for a headless automation sharer, wrong for every app with a
person in front of it — so each host has to assert the safe value, and a
wrong answer here is silent: the share works perfectly and admits
strangers),
so they run on Linux CI (`linux-protocol`) instead of only in the mac
build.

`AccountProfileStoreTests` covers `AccountProfileStore` — the multi-account
registry the **Linux and Windows apps share**. A profile IS a tsnet
state directory; the platform part is an injected `AccountProfileLayout`
(`.xdg()` / `.windowsLocalAppData()`), which is what lets Linux CI test the
Windows layout. It carries one migration knob, `seedStatePath`, used by
Windows only: it makes the first
seeded profile adopt a pre-existing STATE DIRECTORY that sits outside the
`profiles/` subtree (Windows' `%LOCALAPPDATA%\Tailscreen\tailscale`, so
introducing accounts signs nobody out — adopted unconditionally, so a first run
that never logged in and the run after it agree, and so a corrupt registry
re-seeds onto the login still on disk instead of orphaning it). The type is
neither `ObservableObject` (the stand-in this module ships on Linux is a
different protocol from the identically-named one swift-cross-ui hosts observe,
so each host owns the reactive wrapper — the mutators return whether they
changed anything for exactly that) nor `Sendable` (one unlocked JSON file, kept
inside one `@MainActor` model by strict checking). The macOS app keeps its own
UserDefaults-backed `ProfileStore`/`TailscreenProfile`, whose names would
collide through `ProtocolReexports`'s `@_exported import`.

Suites that touch mac-only symbols stay in
`Apps/macOS/Tests/TailscreenTests`: anything importing an Apple framework,
the server/`AppState`/`VideoDecoder`/`VoiceChannel` decision suites, and the
impairment/fuzz cluster (`RTPLossyChannelTests`, `ParserFuzzTests`,
`SoakTests`) whose shared `LossyChannel`/`ParserFuzzHarness` helpers still
have mac consumers. When you add a pure suite for portable code, put it in
the package target; when it mixes in a mac symbol, it stays mac-side.

The Linux/Windows roadmap this enables (viewer first, then sharer) lives in
`docs/porting-plan.md`.

## Architecture & data flow

Capture and encoding live in a separate **helper subprocess** (`Tailscreen --capture-helper`), spawned per share. Process death is the only reliable signal that clears `replayd`'s per-bundle slot, so isolating SCStream + VideoToolbox in a child means Stop Sharing always works — no stuck menubar recording badge.

```
TailscreenApp (@main, AppEntry dispatch)
 ├─ Main process
 │   └─ AppState (@MainActor)
 │        ├─ presentNativePicker() ── spawn ─▶ picker-helper subprocess
 │        │       (returns archived SCContentFilter via stdout)
 │        ├─ TailscaleScreenShareServer
 │        │    ├─ HelperScreenCapture ──spawn──▶ capture-helper subprocess
 │        │    │     (archived SCContentFilter sent over stdin;
 │        │    │      encoded AUs come back over stdout)
 │        │    └─ RTPPacket → UDP/7447 (TailscaleNode.listenPacket)
 │        │       + TCP/7447 (annotations + metadata)
 │        ├─ TailscaleScreenShareClient
 │        │    └─ UDP/7447 → RTP depacketize → VideoDecoder → MetalViewerRenderer
 │        │       + TCP/7447 (annotations out)
 │        ├─ VoiceChannel (PCM ↔ Opus ↔ RTP, bidi over UDP/7447)
 │        ├─ TailscalePeerDiscovery   ── LocalAPI + TCP probe
 │        ├─ TailscaleIPNWatcher      ── IPN bus subscription
 │        ├─ TailscaleAuth            ── browser-based login
 │        └─ TailscreenMetadataService ── share name, resolution, request-to-share
 ├─ picker-helper subprocess (--picker-helper, short-lived)
 │    └─ NSApplication + SCContentSharingPicker.present()
 │       → archive selected SCContentFilter → stdout → exit
 └─ capture-helper subprocess (--capture-helper)
      └─ ScreenCapture(SCStream) → VideoEncoder → CaptureHelperWire (stdout)
```

Both helper subprocesses are short-lived for the same reason: ScreenCaptureKit's APIs couple to `replayd` / WindowServer via XPC, and process death is the only reliable way to clear those couplings. The picker-helper exits the moment the user picks (or cancels); the capture-helper lives for the duration of one share.

The viewer `NSWindow` (with its `CAMetalLayer`) is held for the process lifetime to avoid an autoreleasepool teardown race with VideoToolbox/Metal on disconnect.

### UI surfaces

Two SwiftUI scenes share one `AppState`: a `Window` (`MainWindowView`, scene id `TailscreenApp.mainWindowID`, presented at launch) and the `MenuBarExtra` popover (`MenuBarView`). The app sits at `.regular` activation policy permanently — asserted once at `didFinishLaunching`, never toggled — so the Dock icon, ⌘Tab, and the hand-built `NSMenu` are always available. AppKit callers reach the window through `AppState.presentMainWindow()`, which invokes a stashed SwiftUI `openWindow` action (`openMainWindowAction`, set from both scenes' `onAppear`) with an `NSWindow.identifier` fallback.

- **Window layout.** The title bar is hidden and an **empty** unified-style `NSToolbar` is attached (`TitlebarConfigurator`) purely so macOS centers the traffic lights in the ~52pt title-bar region — there's no public title-bar-height API. `HubHeader` is ordinary content underneath it (wordmark + tailnet name, filter, refresh, account button, `WindowDragGesture`), *not* a SwiftUI `.toolbar`: toolbar item labels drop custom views, which rendered the avatar as an empty pill.
- **Account menu.** `AccountMenuButton` is an `NSViewRepresentable` around a real `NSMenu` for the same reason — SwiftUI's `Menu` flattens custom row labels to plain text, so Tailscale-style two-line rows (avatar image + login over tailnet, checkmark on the active account) need `NSMenuItem.attributedTitle` + `.image`. Clicking a row switches accounts; ⌥ swaps a non-active row for "Remove Account…" (native alternate items).
- **Avatars.** `AvatarStore` (in `Theme.swift`) caches profile pictures by URL in memory, fetching on first miss and publishing on arrival so monograms swap to real pictures live; `AvatarStore.circular` renders the AppKit crop `NSMenuItem.image` needs. `MonogramAvatar`'s color is a djb2 hash of the name — **not** `hashValue`, which is per-process seeded and would reshuffle colors every launch. Every miss/failure degrades to the monogram.
- **Accessibility.** Status that reads as color — the viewer-health dots, the peer-detail quality dot — must also be spoken: those dots are `accessibilityHidden` and their meaning is folded into the adjacent label (the `.help()` tooltips are mouse-only and don't count). Animations are gated on `@Environment(\.accessibilityReduceMotion)`: the list glide, the row expand, and especially `PeerRowSkeleton`'s `repeatForever` pulse, which holds static instead. Hover-only affordances are banned — keyboard and VoiceOver can't reach them, which is why the peer row's actions are real always-visible buttons. Anything wrapping scaling text uses `minHeight`, never `height` (72 of the app's ~76 font call sites are semantic, so text really does grow with the system text size); fixed *widths* around text or SF Symbols — the peer-detail label gutter, the menu icon slots — use `@ScaledMetric` so the column grows with what it holds.
- **Peer detail.** Clicking a row in the Screens list connects (when fully idle); the trailing chevron expands `PeerDetailView` — live share resolution/codec, View Screen / Ask to Share, MagicDNS + IPv4/IPv6 (copyable), ACL tags, remembered `Access` (StableNodeID-keyed, same identity the admission gate uses), and a `Route` line. Route/latency come from data already in hand: `TailscreenPeer.curAddr`/`.relay` ride the LocalAPI status seed (netmap ticks carry no path info, so `publishMerged` preserves them), and `AppState.peerLatencyMs` times the metadata TCP fetch — an estimate over the live path, not a wire ping. `PeerRoute` / `ConnectionQualityTier` (`PeerConnectionInfo.swift`) are the pure classifications behind it.
- **Which surface gets what.** The split is by *kind*, not by convenience: anything that decides something about a **person** — approving a viewer, granting control, dropping a connected viewer — renders in **both** the hub window and the menubar popover, sharing one component (`PendingViewersList`, `ControlRequestsList`, `RemoteControlGranteeBanner`, `ViewersList` — all non-private in `MenuBarView.swift` for exactly that reason). Continuous *session* controls (mic, audio device, drawing) stay in the popover, which is the sharer tool. A decision surface that lands on only one of the two is a bug; `ViewersList` was menubar-only by omission, which made dropping a viewer the one sharer action with no path outside the popover.
- **Capture outline.** `CaptureOutlineWindow` draws a border around exactly the region being captured, for the whole share — the recording indicator, and the reason the plan has no tray icon. Two rules: it tracks the *region* (reusing `SharerOverlayWindow`'s frame statics and miss threshold, so the two can't disagree about where the shared region is), and it must never be captured itself (`sharingType = .none`; without it a display share draws the border into the video and every viewer sees a frame around their own view). It is a separate window from `SharerOverlayWindow` on purpose: that panel is built lazily and, in display mode, deliberately sits *inside* the capture region so sharer strokes reach viewers — both wrong for an outline. Its mode is immutable, so `AppState.showCaptureOutline()` rebuilds it on the mid-share "Change Source…" path, exactly like the annotation overlay.

## Network protocol — port 7447 (TCP **and** UDP)

**Every wire constant below is pinned by `Apps/macOS/Tests/TailscreenTests/WireByteRegistryTests.swift`** — one registry table per channel (TCP message types, UDP control bytes + caps bits, capture-helper `OutType`/`InType`, picker framing, RTP payload types + reserved SSRCs), asserting exact values, exhaustiveness, and per-channel uniqueness. Adding a wire byte means adding a registry row in the same commit; renumbering a shipped byte breaks deployed peers and the registry will name it. Uniqueness is per channel on purpose: TCP types and UDP control bytes overlap by design, as do `OutType`/`InType` (different pipes).

- **Video — UDP RTP.** AVCC NAL units; parameter sets (SPS+PPS for H.264, VPS+SPS+PPS for HEVC) in-band on every keyframe; PLI-driven keyframe roughly every 2 s. UDP loss is accepted, but recovered where cheap: **NACK-based selective retransmission** sits in front of the PLI path. The viewer auto-detects the codec from the RTP payload type (`97` HEVC, `96` H.264) — no out-of-band negotiation.
- **Loss recovery — NACK + receiver feedback (capability-negotiated).** A viewer advertises support in an **extended HELLO** `[0x00][caps:1]` (bit0 NACK, bit1 receiver-report, bit2 FEC); the sharer replies with an **extended HELLO_ACK** `[0x04][ssrc:4][serverCaps:1]` (6 bytes) *only* to cap-advertising viewers, and its serverCaps additionally carries two sharer-only bits the viewer uses to gate its own UI: **bit3 `.remoteControl`** ("this build/platform can inject viewer input" — the viewer offers Request Control only when set, else hides it rather than sending a `.controlRequest` a non-injection sharer would silently drop) and **bit4 `.annotations`** ("this sharer renders/relays viewer annotations" — advertised iff the host passed `rendersAnnotations: true`, which is the default; a host with no overlay passes false, the same conditional-capability shape as `.remoteControl` — the viewer disables its annotation toolbar when absent so it never draws local-only strokes reaching nobody) — a legacy viewer's strict 5-byte `decodeHelloAck` rejects the 6-byte form, so it stays PLI-only (the whole feature degrades cleanly both directions). New control bytes (all ≤ 0x7F so `looksLikeControl` is untouched): **`0x0A NACK`** (viewer→sharer, RFC-4588 generic-NACK FCI `[count:1][(pid:2,blp:2)×count]`, ≤16 entries) requests retransmission of missing seqs in that viewer's seq space; the sharer resends byte-identical RTP from a bounded send-side ring (`RetransmitBuffer` — templates shared across viewers since only the header bytes `rewriteRTPHeader` rewrites differ; triple-evicted by age/bytes/count) under a per-viewer 25 %-of-bitrate token budget, falling back to PLI when the gap is evicted or over budget. **`0x0B RECEIVER_REPORT`** (viewer→sharer, ~1 Hz, `[fracLostQ8:1][extHighestSeq:4][jitterTicks:4][lastPingTs:8][delaySincePingMs:2]`) and **`0x0C PING`** (sharer→viewer, ~1 Hz, `[serverUptimeNs:8]`, echoed in the RR for RTT) feed the receiver-feedback congestion controller (`nextCongestionDecision`), which evolves the fairness/adaptive sweep: RR loss fraction (or legacy PLI count) drives the ±25 %/+10 % bitrate arm, NACK-recovered loss weighs half a PLI, and an **fps ladder** (60→30→15, applied via the capture-helper `setFrameInterval` command) is the second lever once bitrate bottoms out. In NACK mode the viewer's `RTPReorderBuffer` holds an open gap by **time** (`TransportTuning.reorderGapHoldNs`, ~300 ms) under a generous packet hard-cap (`nackReorderDepth`, 1024), not by packet count: the old count-based window (64) overflowed in tens of ms at video bitrate — long before a retransmit could arrive ~1 RTT later — so any keyframe (hundreds of packets) that lost a packet was torn and never reassembled, the viewer never installed parameter sets, and the stream stalled (`TS-GENERIC-001`). The time hold lets the retransmit fill the gap; genuine loss is still declared once the hold elapses (the `NACKScheduler` drives PLI independently, so the hold never delays keyframe recovery). Deriving the hold from `NACKScheduler.rttEstimateNs` is a noted follow-up. The viewer also gates the depacketizer's own loss-PLI (the `NACKScheduler` owns recovery). PLI (`0x03`) remains the universal fallback for legacy peers and abandoned gaps. **`0x0D FEC`** (sharer→viewer, `[baseSeq:2 BE][count:1][xor body]`, cap bit2 `.fec` on the same extended HELLO/HELLO_ACK) layers zero-RTT single-loss recovery in front of NACK: one XOR parity datagram per group of ≤ N media packets (groups chunked per broadcast batch — never spanning batches, so throttled keyframe-only viewers stay coherent), body = XOR of `[len:2][byte1][timestamp:4][payload]` zero-padded (byte 1 + timestamp covered so the recovered **marker** packet reconstructs), computed once on the seq=0/ssrc=0 templates and fanned out with only `baseSeq` rewritten per viewer — the same economics as retransmits — with each group's parity INTERLEAVED right after that group's last media packet (never batch-trailing: a multi-hundred-packet keyframe would evict early groups from the viewer's bounded buffer and leave early gaps NACK-eligible before recovery data hit the wire). Parity rides the control plane (no media seq consumed), so parity loss is silent and free. Adaptive: the sweep's pure `fecSweepDecision` is per-viewer first — a viewer is gated only when its OWN path passes RTT > 150 ms ∧ raw loss > 2 % (cross-viewer mixing can't turn FEC on with nobody gated), group size ladders 10/7/5 from the gated viewers' worst raw loss (residual + recovered, each against that viewer's own expected packet count), and FEC gates off after two consecutive clean windows; the encoder is compensated to N/(N+1) of the congestion rate (`fecCompensatedBitrate`, scaled-floor-clamped) ONLY while the gated set is non-empty, with a keyframe forced when compensation turns on and the compensated rate re-pushed after every helper (re)spawn. The RR grows an optional trailing `[fecRecovered:2 BE][nackRecovered:2 BE]` (24-byte form, FEC-negotiated only; tolerant decode reads 0 from the legacy 20-byte and FEC-era 22-byte forms): recovered packets count as *received* in `fracLostQ8` (residual loss drives the bitrate arm) while `residual + fecRecovered + nackRecovered` reconstructs raw link loss for the FEC arm — the anti-oscillation split. **Both** recovery counters feed raw loss: a served NACK retransmit masks link loss exactly like an FEC recovery, so omitting `nackRecovered` let NACK's own success (once retransmits actually land — see the time-held reorder buffer above) read as a clean link and keep FEC off on the very high-RTT paths where its zero-RTT recovery beats NACK's per-loss round trip. `NACKScheduler.drainNackRecovered()` counts served-retransmit fills viewer-side. Viewer side, the FEC machinery arms on the FIRST parity datagram received (not at bare negotiation — the server always advertises `.fec`, and a clean link that never sees parity keeps phase-1 NACK timing and pays no buffering; it disarms after ~3 s parity-idle): `FECGroupBuffer` solves parities via `FECCodec.recover` and feeds recovered packets through the **same ingest path** as received ones (RR counts them received; `NACKScheduler.noteRecovered` clears the pending gap without polluting the RTT estimate AND advances the cursor past a recovered tail-of-batch marker so the next batch opens no phantom gap; a late original dedups in the reorder buffer), while FEC-mode scheduler tolerances (N+2 packets / 25 ms, switched in place) let NACK fire only for multi-loss groups. Old peers drop the unknown 0x0D / caps bit — the whole matrix degrades to NACK-or-PLI. **Color/bit-depth ride the SPS VUI in-band** (primaries/transfer/matrix + bit depth): the sharer captures + encodes in the source display's space (BT.709 by default, Display P3 on wide-gamut displays, opt-in BT.2020 PQ 10-bit HEVC Main 10 for HDR via `TAILSCREEN_ENABLE_10BIT` / `TAILSCREEN_ENABLE_HDR`), VideoToolbox writes those into the SPS, and the viewer reads them back onto the decoded buffer + derives its `CAMetalLayer.colorspace` — so there's no wire-protocol change for color. The only new control byte is PROFILE_NO (`0x09`, viewer→sharer): "I decode this codec but not its bit depth", latching the share to 8-bit HEVC (a lighter cousin of CODEC_NO `0x07`'s H.264 fallback). The whole 10-bit/HDR switch is capability-gated and off by default; Phase 1 (P3 tagging at 8-bit) is always on.
- **Viewer admission.** A HELLO only joins the fan-out set if the sharer's approval gate allows it: "Require approval for new viewers" defaults **on** (tri-state UserDefaults migration; `TAILSCREEN_OPEN_DOOR=1` is the automation escape hatch), parking unknown viewers pending (HELLO_PENDING `0x06`) until Accept/Deny. A persistent per-peer allow/deny store (`ViewerAccessPolicyStore`, keyed by Tailscale StableNodeID from the server's own LocalAPI lookup — never by wire-payload claims) auto-admits remembered-allow peers and rejects remembered-deny peers; deny outranks the gate, so blocked peers are rejected even in open-door mode. Denial is signalled with HELLO_DENY (`0x08`, server→viewer) followed by SERVER_BYE so the viewer can say "declined" instead of "sharer stopped"; old viewers ignore the unknown byte. The sharer can also **one-time kick** a connected viewer (the ✕ on its SharingCard row → `disconnectViewer`): the same HELLO_DENY + SERVER_BYE ride the same symmetric expel teardown as the blocked-peer path, but nothing is remembered — the peer's next HELLO re-runs the admission gate. A 30 s expelled-addr quiet window (`expelledQuietDecision`) answers the kicked client's straggler KEEPALIVEs with denial instead of re-registering them (a keepalive would otherwise re-park a pending row — or, in open-door mode, silently readmit); only a fresh HELLO clears it. Viewer-side, the same HELLO_DENY byte is worded by context: still on the approval placard ⇒ "declined", already watching ⇒ "disconnected by sharer" — no wire change.
- **Audio — UDP RTP, separate SSRC space.** Opus (libopus via the local `OpusKit`), mono, 48 kHz, one 20 ms frame (960 samples) per packet — royalty-free, software-only, and portable to Linux/Windows (it replaced the AudioToolbox AAC-LC path). Bidi sharer↔viewer plus viewer-to-viewer relay (the server forwards inbound viewer audio byte-for-byte after validating the source-assigned SSRC). **Two payload types share the audio path:** voice is PT 98, shared system/computer audio is PT 99 (viewers demux by PT, same auto-detect philosophy as video's 96/97; old viewers reject PT 99 and silently drop it). SSRC spaces are disjoint on purpose — sharer voice owns 0, system audio owns the reserved SSRC 1, viewer-assigned SSRCs start at 2. System audio flows sharer→viewers only (captured in the helper via `SCStreamConfiguration.capturesAudio` + `excludesCurrentProcessAudio` so played-back viewer voices are never re-captured/looped); the inbound gate still only accepts PT 98 from viewers, which doubles as the anti-spoof rule for PT 99. The viewer mixes system audio through a dedicated `AVAudioPlayerNode` (`MicCapture`), summed with voice by `mainMixerNode`.
- **Annotations / control — TCP, framed.** `[type:1][len:4 BE][payload:N]`, payload is JSON-encoded. TCP gives reliable delivery so strokes don't drop. **Gated to admitted viewers:** the TCP back-channel accepts a connection from any peer that can dial 7447, so inbound annotation ops are honoured only when the connection's peer IP matches an *admitted* viewer (present in the UDP fan-out set) — a pending/denied/blocked/expelled peer's ops are dropped (never applied to the sharer's overlay, never fanned out), and `expelViewer` severs a blocked peer's annotation connection by IP along with its video. The listener threads each connection's `remoteAddress` to the `onAnnotation` / `onRequestToShare` / `onControlRequest` / `onInputEvent` handlers for this. **Viewer-side gating:** the annotation toolbar is disabled unless the sharer advertised `ScreenShareCaps.annotations` (bit4) in its HELLO_ACK (`AppState.sharerSupportsAnnotations`, default true so the mac→mac path shows tools with no disable-flash) — a future non-rendering sharer would otherwise leave the viewer drawing local-only strokes.
- **Remote control — TCP, framed.** Opt-in, single-grantee viewer input injected on the sharer's Mac. New message types ride the same framed channel: `.controlRequest` (`0x06`, viewer→sharer), `.controlGranted` (`0x07`) / `.controlRevoked` (`0x08`, JSON `{reason}`, sharer→viewer), `.inputEvent` (`0x09`, viewer→sharer, JSON `InputEvent` — mouse move/down/up/scroll + key down/up, coords normalized `[0,1]` top-left like `Annotation`; **the key model is platform-neutral**: keys are USB HID keyboard-page usage IDs and modifiers the five-bit `KeyModifiers` set (shift/control/alt/meta/capsLock), with each endpoint translating to/from native codes — macOS via the bijective `MacKeyCodeMapping` table — so no `CGKeyCode`/`CGEventFlags` ever rides the wire; buttons are left/right/middle, and button/scroll events carry the modifier snapshot so modified clicks work), `.controlReleased` (`0x0A`, viewer→sharer "I'm done controlling" so the sharer revokes and the UI/gate clear in step — no zombie grant). (`0x0A`–`0x0C` also name UDP NACK/RR/PING, but that's the disjoint UDP control-byte space — TCP message types and UDP control bytes don't collide.) Old peers skip the unknown type bytes. The framed parser caps a single payload at `ScreenShareMessage.maxPayloadLength` (1 MiB) and marks itself `isCorrupt` on an oversized declared length so a peer can't slow-stream a bogus 4 GiB frame to exhaust memory — the receive loop closes the connection. **Support gating:** the viewer only offers Request Control when the sharer advertised `ScreenShareCaps.remoteControl` (bit3) in its HELLO_ACK: static "this platform can inject" support (always set by the macOS sharer, omitted by a future non-injection sharer), distinct from the runtime "Allow control requests" toggle + Accessibility gate that decline a *live* request with `.controlRevoked`. **Security model:** a viewer must be an admitted viewer to even request control; the sharer grants to **one** connection at a time (granting a new one revokes the old); the server-side gate (`RemoteControlPolicy.shouldInject`) admits `.inputEvent`s only from the exact grantee's `connectionID` — unspoofable and un-inheritable across a NAT rebind — behind a per-share event-rate ceiling (reset per grant); the grant auto-revokes on the grantee's disconnect (TCP close, UDP BYE, idle sweep, expel), on Stop Sharing, and on the viewer's own `.controlReleased`, and is instantly revocable by the sharer (SharingCard Stop button, File → Stop Remote Control, or the ⌃⌥. panic hotkey). The injector's revoke path is TOCTOU-safe (an `active` gate atomic with the pending queue drops any event that raced the revoke) and synthesizes a button-up for any button held mid-drag so revoke never leaves a stuck button; `CGEventFlags` are *constructed* from the neutral `KeyModifiers` bits (`RemoteControlInjector.eventFlags`) so no wire value reaches an event unmasked, and a HID usage with no mac key (Insert, PrintScreen) is dropped, never guessed. Injection is `CGEvent` in the **main process** (needs **Accessibility** TCC, not Screen Recording — no `replayd` coupling, so no helper isolation); a grant is refused (with a prompt/deep-link) if that permission is missing, rather than installing a dead grant. Normalized coords map onto the captured region's live global-Quartz rect per share kind (`RemoteControlMapping`: display bounds / on-screen window bounds / **union of the shared app's on-screen window rects** — an app share confines the *pointer* to that app's windows, not the whole display). **Keyboard is deliberately whole-Mac** (keystrokes land on the sharer's frontmost app, not scoped to the shared window/app — scoping keystrokes isn't reliable and was ruled out); the sharer is warned of this scope at grant time via a caption + tooltip on the SharingCard's Grant control.
- **Metadata — TCP request/response on the same port.** Share name, resolution, request-to-share prompts. A request-to-share (framed type `0x04`) is answered with `shareResponse` (`0x05`, JSON-encoded `TailscreenRequest` `.acceptShare`/`.declineShare`) **on the same TCP connection the request arrived on** — no dial-back, so the answer provably reaches the actual requester. The requester holds the connection open awaiting the response (timeout/EOF ⇒ no-answer, which is also what pre-`shareResponse` peers produce; unknown frame types are skipped by all parsers, so the addition is backward compatible). The receiver dedupes/caps the pending request set by the peer's **source IP** (not the spoofable wire-claimed hostname) so a flood can't stack banner rows or pin unbounded 120 s connections, and the requester's response wait classifies a dead-socket `readFailed` (near-instant) from a poll timeout (full interval) via `ReceiveLoopPolicy.classifyReadFailedAsError` instead of hot-spinning. Accepting a request one-time **pre-approves** the requester's IP (`server.preApproveViewer`) so their imminent HELLO auto-admits without a second approval prompt. The same channel carries the **metadata query pair** behind the peer list's sharing-status filter: `.metadataRequest` (`0x0B`, empty payload) is answered with `.metadataResponse` (`0x0C`, JSON-encoded `TailscreenMetadata` — share name / resolution / `isSharing`, display strings parser-clamped to 128 chars) on the same connection, served by `AppState`'s always-installed `onMetadataRequest` handler (`TailscreenMetadataService.wireMetadata()` answers an idle not-sharing snapshot when no share has run, so "reachable but not sharing" is distinguishable from no-answer). The fetch half (`TailscreenMetadataClient.fetchMetadata`, in TailscreenTransport) is deliberately **lazy** — `AppState.refreshPeerShareStatus()` dials online Tailscreen peers concurrently only off `discoverPeers()` (menu open / manual refresh) and when the "Only screens being shared" filter turns on — and all failure modes (timeout, EOF, legacy peer dropping the unknown byte) collapse to nil = status-unknown, never "not sharing". (TCP `0x0B`/`0x0C` also name UDP RR/PING — disjoint spaces, see the registry.)
- **Discovery probe.** Parallel TCP/7447 probe across the tailnet to identify Tailscreen instances.

## Capture-helper IPC

Capture and encoding run in a child process spawned per share — `Tailscreen --capture-helper`. Process death is the only reliable way to clear `replayd`'s per-bundle slot, so isolating `SCStream` + VideoToolbox in a child means "Stop Sharing" always works.

- **Spawn.** The parent `Process()`-execs the same binary with `--capture-helper`. Stdin and stdout are pipes; stderr streams through to the parent's terminal. Quality knobs (fps cap, codec preference, bandwidth ceiling, encoder quality — see `QualitySettings`) travel as spawn-time env vars (`TAILSCREEN_FPS_CAP` / `TAILSCREEN_CODEC_PREF` / `TAILSCREEN_MAX_BITRATE` / `TAILSCREEN_ENCODER_QUALITY`, same pattern as `TAILSCREEN_FORCE_H264`, which still wins over the codec preference; the **explicit `hevc` preference** is the no-safety-net variant — the encoder ladder drops its H.264 rung (`VideoEncoder.allowsH264Fallback`) and the server ignores viewer CODEC_NO instead of latching the automatic H.264 fallback, so H.264-only viewers stay unserved by the user's own choice); the child env is always seeded from the parent's before overlaying (`Process.environment` replaces, it doesn't merge). The color pipeline uses the same env channel: `TAILSCREEN_FORCE_8BIT=1` (set by the server's `force8bit` latch on a viewer PROFILE_NO) pins the helper's `ColorInfo` to 8-bit; `TAILSCREEN_ENABLE_10BIT` / `TAILSCREEN_ENABLE_HDR` opt into the 10-bit / HDR capture path (still gated on the display being capable, probed via `CGColorSpace.isWideGamutRGB` / `NSScreen` EDR headroom).
- **Startup.** The helper waits on stdin for a framed `contentFilter` message — payload is a JSON-encoded `PickerSelection` (display / window / bundle IDs) from the picker-helper — before bringing the SCStream up. The helper resolves those IDs against `SCShareableContent` (legal inside the helper, never in the main process) and rebuilds the filter on its side. There's no other entry point: every share routes through the picker. **Cloaked Apps** (Settings → Cloaked Apps, Tuple-style "hide these apps from viewers") rides the same JSON: the parent bakes the persisted cloak list (`AppCloakStore`, main toggle default on) into `PickerSelection.excludedBundleIDs` via `AppState.applyingShareTransforms` — shared by share-start and Change Source, which is also where `captureAudio` is now injected on both paths — and the helper rebuilds a `.display` share as `SCContentFilter(display:excludingApplications:exceptingWindows:)` so cloaked apps' windows never reach viewers (missing key decodes `[]`, so old JSON stays valid). Window/app shares never cloak: their include-list already limits capture, and an explicitly picked app wins over its cloak entry. Mid-share cloak edits re-push the filter through the tracked `changeSource` restart (debounced ~500 ms like the quality ceiling); a cloaked app *launching* mid-share forces the same re-push, because an app that wasn't running at filter-build time never resolved into the exclusion list.
- **Wire.** Framed binary — `[type:1][len:4 BE][payload:N]`. Message types: encoded access unit (AVCC), parameter sets (H.264 SPS/PPS or HEVC VPS/SPS/PPS), preview thumbnail, **heartbeat**, **system-audio access unit** (raw Opus packet, no keyframe flag — `OutType.audioAccessUnit 0x07`), log line, fatal, user-stopped; control commands request-keyframe, set-bitrate, content-filter, **set-audio-enabled** (`InType.setAudioEnabled 0x04`, 1-byte on/off latch), **set-frame-interval** (`InType.setFrameInterval 0x05`, `[fps:4 BE]` — the fps-ladder congestion lever, reconfigures the SCStream's `minimumFrameInterval` live in the helper, never the main process), shutdown. The heartbeat is a ~1 Hz liveness ping emitted off *any* delivered SCStream sample (including the `.idle` frames a static screen still produces, which carry no pixel buffer and so produce no AUs) — a content-independent proof the capture pipeline is alive. `HelperFrameWriter` is lock-serialized because it's now written from **four** threads: the encoder output thread (AUs/params), the MainActor (previews), the SCStream video delegate queue (heartbeats), and the SCStream audio-output queue (system-audio AUs). Whether system audio is captured at all rides the `contentFilter` JSON (`PickerSelection.captureAudio` — a non-optional `Bool` whose custom decoder defaults a missing key to `false`, so old picker-helper JSON still decodes; kept non-optional to satisfy swiftlint's `discouraged_optional_boolean`); the `setAudioEnabled` latch gates *emission* so mute/unmute is instant (no `updateConfiguration` churn) and is re-sent by the server after every helper (re)spawn — like `TAILSCREEN_FORCE_H264` — so restarts preserve the toggle.
- **Lifecycle.** The helper writes encoded AUs directly from the encoder thread to preserve order. On Control Center "Stop", the helper exits 0 with a `userStopped` message and the parent tears the share down quietly. Any other helper exit triggers up to 3 auto-restarts within a 30 s window before giving up. Restart re-spawns against the same cached selection — the JSON bytes are reusable across helper PIDs because each helper re-resolves the IDs independently. The mid-share "Change Source…" flow (`AppState.changeShareSource` → `server.changeSource(filterData:)`) replaces the cached bytes and rides this exact restart path: the helper is never hot-swapped (it refuses a second `contentFilter`), viewers recover via the fresh helper's in-band parameter sets, and the sharer overlay is rebuilt + a `.clearAll` annotation broadcast so stale strokes don't float over the new content. **Hung-helper watchdog:** the parent ticks a liveness clock on every helper message; if a live helper goes silent for 15 s (SCStream wedged without exiting — process-death detection can't catch that) the idle sweep restarts capture. The heartbeat is what keeps a *healthy* static-screen share from tripping it. On by default; `TAILSCREEN_DISABLE_HELPER_WATCHDOG=1` is the escape hatch.

## Picker-helper IPC

The macOS native `SCContentSharingPicker` runs in its own short-lived child process — `Tailscreen --picker-helper` — for the same defensive reason as the capture helper.

- **Spawn.** The parent `Process()`-execs the same binary with `--picker-helper`. Only stdout is a pipe; stdin isn't used and stderr streams through.
- **Wire.** A single framed payload on stdout: `[length:4 BE][JSON bytes:N]` — JSON-encoded `PickerSelection` (kind + display ID / window ID / bundle IDs). `length == 0` means the user cancelled. Exit code: 0 on selection, 1 on cancel, ≥2 on error. We can't ship the live `SCContentFilter` itself because the class doesn't conform to NSCoding.
- **Lifecycle.** The helper presents the picker with all four modes allowed (display / single-window / single-app / multi-app). On the first observer callback, it writes the framed payload, briefly sleeps to flush, and exits. The parent waits for the payload, then `waitUntilExit()` so consecutive picker spawns can't race the singleton's teardown.

## Swift 6 conventions used here

- `@MainActor` on all UI-touching state and anywhere that constructs an `NSWindow`.
- `@unchecked Sendable` on networking classes that handle their own thread safety. We're owning the invariants, the compiler isn't checking them.
- `CVPixelBuffer` is **not** `Sendable` — convert to `CGImage` *before* hopping to `@MainActor` (e.g. for preview thumbnails).
- No `Task { … self … }` in `deinit` — do synchronous cleanup; capturing `self` after deinit starts is undefined.
- `ObservableObject` + `@Published` for UI-bound state; `@StateObject` to own, `@EnvironmentObject` to consume.
- Logging: prefer `TSLogger` from TailscaleKit. Bare `print` is fine in legacy/example code, avoid in new code.
- Errors at the UI: catch and surface via `appState.showAlertMessage(title:message:)` rather than swallowing.

## Linker / package conventions

`Package.swift` links libtailscale via a **relative** path:

```swift
linkerSettings: [.unsafeFlags(["-L", "../../Packages/TailscaleKit/lib"])]
```

Never make this absolute — it breaks portability and CI. Both the `Tailscreen` target and the `TailscreenTests` target carry this flag.

## Localization

User-facing strings are localized through SwiftPM resources. `Package.swift` sets `defaultLocalization: "en"`, and the base catalog lives at `Apps/macOS/Sources/Resources/en.lproj/Localizable.strings` (alongside the unlocalized PDF/SVG assets already under `Resources/`, both picked up by the existing `.process("Resources")`).

- **Route every user-facing string through `L(_:)`** (defined in `Apps/macOS/Sources/Localization.swift`). It calls `String(localized:bundle: .module)` — the `bundle: .module` part is essential. SwiftUI's implicit `LocalizedStringKey` lookups (`Text("…")`, `Button("…")`) and a bare `String(localized:)` both default to `Bundle.main`, which in a SwiftPM executable does **not** contain the `.lproj` resources. Those live in `Bundle.module`.
- **SwiftUI:** wrap as `Text(L("…"))`. For `Button`/`Toggle`/`Picker`/`Section`/`Label`/`.help`/`.accessibilityLabel`/`.accessibilityHint`, pass `L("…")` (a plain already-localized `String`, so no double lookup). **AppKit:** `NSMenuItem(title: L("…"))`, `alert.addButton(withTitle: L("…"))`, `content.title = L("…")`, etc.
- **Keys are the English source text** (base-language-as-key). Interpolation works: `L("Viewing \(host)")` looks up `"Viewing %@"` (Int → `%lld`). Keep keys in the catalog byte-for-byte in sync with call sites.
- **Don't localize** log lines (`TSLogger`/`print`), error codes (`TS-…`), key-equivalent glyphs (`⌘Q`), SF Symbol names, or brand nouns ("Tailscreen", "Tailscale").
- **To add a language:** copy `en.lproj/Localizable.strings` to `<lang>.lproj/Localizable.strings` (e.g. `sv.lproj`) under `Apps/macOS/Sources/Resources/` and translate the values only. No code changes.

## Common pitfalls

- **`swift build` fails with linker errors** — you skipped `make tailscale`. The Go build emits `libtailscale.a`; without it nothing links. (And "no Package.swift" at the repo root means you forgot to `cd Apps/macOS` first.)
- **Two local instances see no peers** — both processes are sharing one Tailscale state dir. Use `./test-local.sh` (or set `TAILSCREEN_INSTANCE` manually).
- **Editing `Packages/TailscaleKit/Sources/` directly** — those paths are symlinks into the upstream submodule. Add a patch under `Packages/TailscaleKit/Patches/` instead.
- **Port 7447 is hardcoded** across the discovery, server, client, and metadata paths. If you make it configurable, search for `7447` and update everywhere it appears.
- **Auth flow needs an active node** — interactive login only works after `Start Sharing` or `Connect to…` has initialized the tsnet node.
- **CI uses submodules.** Workflows already pass `submodules: recursive`; if you add a new workflow that builds, do the same.
- **Don't call `SCShareableContent` from the main process.** It registers the parent with `replayd`, and the helper child's subsequent `SCStream` then fails with "application connection being interrupted". Never call `SCShareableContent` in the parent — and don't reintroduce a parent-side Screen Recording permission gate either. The native `SCContentSharingPicker` (running in the picker-helper) drives the TCC prompt on first use; preflighting from the parent is unnecessary and was removed.
- **Don't present `SCContentSharingPicker` from the main process either.** Same family of APIs, same defensive isolation — spawn `--picker-helper` instead. The picker subprocess exits the moment the user picks, so its XPC handles never live alongside the long-running main process.
- **Don't deserialize an `SCContentFilter` in the main process.** The decoded filter retains XPC handles to system services; the unarchive happens only inside the capture-helper.
- **Don't add SCStream lifecycle to the main process.** All capture lives in the helper subprocess. The main-process screen-share server only spawns the helper and broadcasts what comes back.
- **Linux CI (`linux-protocol`) fails after touching a package file** — you added an Apple-only dependency to a file in `Packages/TailscreenKit/Sources/`. Keep package files Foundation-only (see the package README's whitelist) or move the mac-bound piece into the app target. Reproduce with `make test-protocol` (works on macOS too).
- **App fails to compile against a package type** ("initializer is inaccessible", "cannot find X in scope") — the declaration is `internal` in TailscreenKit. Mark what the app needs `public` (structs the app constructs need explicit public inits — Swift never synthesizes memberwise inits as public). Test-only seams should stay internal; tests use `@testable import TailscreenProtocol`/`TailscreenTransport`.
- **A peer's "Ask to Share" always reads as "No reply"** — nothing is listening. `TailscaleScreenShareServer` creates a `TailscreenControlListener` when the caller supplies none, but it lives only as long as the share — and an ask to share arrives exactly when the machine is *not* sharing, so port 7447 answers nothing while idle. Every host that wants to be askable must own a listener for as long as its node is up and pass **that** one into `server.start(controlListener:)`; the macOS app does it in `AppState.ensureControlListener`, and both swift-cross-ui apps now do the same on the first successful discovery (idempotent per node, so a profile switch re-points it). Passing it in is also what stops a second listener contending for the port. Two more things: the answer is sent back **on the connection the request arrived on** — never by dialling the requester, which would answer whoever currently holds that address — and accepting must `preApproveViewer(ip:)` the asker, or the person just invited lands at this machine's own approval gate and is asked to wait, which is the same peer prompted twice seconds apart. Accept necessarily happens before a server exists, so both apps hold the IP and replay it in the same locked window that sets the gate and the policies.
- **A sharer's "Deny & Block" appears to do nothing for a moment** — that is the queue, not a bug. The persistent store is keyed by Tailscale **StableNodeID** (never a hostname, which the peer supplies and could therefore choose), and that ID arrives from the sharer's *own* LocalAPI netmap lookup a beat after the connection does. `SharerAccessCoordinator` queues the decision and applies it on the next roster tick — the roster is re-emitted whenever anything about it changes, including the ID resolving, which is what makes the queue drain at all. The row says "Will apply once this peer is identified" rather than looking unpressed. Two rules if you touch it: feed **both** rosters (connected + pending) to `noteRoster` together, or accepting a pending viewer prunes its own queued intent as "gone" at the moment it moves lists; and the prune itself is load-bearing — a Deny & Block on a peer that disconnects before resolving would otherwise land on *the next connection from that address*, which behind one NAT is a different machine. `SharerAccessCoordinatorTests` covers all of it with no tsnet node.
- **On Windows, a share silently loses remote control AND annotations** — the process is not DPI aware. Both features are gated on `WindowsCaptureRegion.resolve` matching the WGC capture item's size against an enumerated monitor, and item sizes are **physical pixels** while a DPI-unaware process is told a 150 %-scaled 3840 × 2160 display is 2560 × 1440. Nothing errors; the match just never happens, and the viewer stops offering both features. In the WinUI app, DPI awareness is owned by **swift-winui's `WindowsAppRuntimeInitializer`** (`SetProcessDpiAwareness(PROCESS_PER_MONITOR_DPI_AWARE)` — v1 is enough: monitor enumeration returns physical pixels). Do NOT set awareness earlier yourself: the app's `init()` used to call `WindowsShareSession.prepareProcess()`, which ran before the initializer, made its `CHECKED(SetProcessDpiAwareness…)` return E_ACCESSDENIED ("already set"), and killed every real-desktop launch with `Failed to initialize WindowsAppRuntimeInitializer: 0x80070005` + fatalError at SwiftApplication.swift:64. `prepareProcess()` is only for non-WinUI hosts where nothing else sets awareness.
- **You changed the Windows app and want to know if it compiles** — build it on Linux: `swift build --package-path Apps/windows --product tailscreen` (with `PKG_CONFIG_PATH` set, as usual). `WinUIVideoView` is the app's only Windows-bound file and carries an `#if os(Windows)` with an off-Windows stub; the WinUI dependencies are `.when(platforms: [.windows])` so SwiftPM prunes them and swift-cross-ui resolves to GtkBackend. The `linux-app` job runs exactly this. The Windows job stays the authority on linking and running — but not on typechecking, which is where the mistakes are and which used to cost forty minutes to discover. Keep any new Windows-only file behind the same `#if`.
- **A Win32 window created off the app's UI thread never appears** — it belongs to the thread that created it, and every state change (show, hide, the `SetWindowPos` inside `UpdateLayeredWindow`) is delivered to that thread's message queue. A Swift concurrency executor thread does not pump messages, so Windows treats the window as hung: cross-thread calls block for five seconds each, and the window is destroyed outright if the thread exits. `WinOverlayKit` owns a thread with a `GetMessage` loop for exactly this, and every entry point posts to it. Do the same for any new window.
- **On Linux, viewers are never offered Request Control** — this X server has no **XTEST** extension. It is an *optional* X11 extension: without it every `XTestFake*` call succeeds and injects nothing, so a sharer that assumed it was there would grant control to a viewer whose every click silently vanishes. `XTestInjector.isTrusted()` therefore probes for it at open, and both hosts withhold `ScreenShareCaps.remoteControl` when it is absent. Three traps if you extend this: X11 has **no wheel** (a scroll is a press/release of button 4/5/6/7 per notch — `X11PointerMapping.scroll` owns the clamp that stops a peer's absurd delta becoming a million synthetic clicks); Xlib **queues client-side**, so a batch that is never `XFlush`ed is a click that never happens, and that is the single most likely way for the path to look broken while every unit test passes; and X11 button numbers are 1/2/3 with **middle as 2**, the opposite pairing to the wire enum's order. Also note the headless `tailscreen-sharer-linux` defaults control **off** and needs `--allow-control` — an unattended process shouldn't invite a peer to take the pointer merely because it can. `xtest-probe --live-check` is the CI gate for the whole path (real injection against Xvfb, pointer read back), and `--audit-keysyms` checks every row of `X11KeyCodeMapping` against Xlib's own tables, which catches a typo'd constant that lands on an unassigned keysym — one key that silently does nothing.
- **On Linux, a share silently loses annotations** — the session has no compositing manager. The sharer's overlay (`Apps/linux/Sources/CGtkOverlay`) is an ARGB window, and on uncomposited X11 there is no per-pixel alpha: the parts we leave transparent paint as opaque black, so the "overlay" would be a black rectangle over the sharer's whole screen. `ts_gtk_overlay_supported()` therefore returns 0 there and `SharerModel` withholds `ScreenShareCaps.annotations`, so viewers correctly grey out their drawing tools — the visible symptom is a disabled toolbar, not a covered desktop, and stderr says why. Two related traps if you extend it: GTK4 has **neither** window placement (`gtk_window_move` is gone) **nor** keep-above, so the window opts out of the window manager entirely via X11 override-redirect and reasserts position + `XRaiseWindow` on every show; and click-through is `gdk_surface_set_input_region()` with an *empty* region, applied on realize (before map) — miss it and the overlay eats every click on the sharer's desktop. `tailscreen --overlay-self-test` is the gate for all of this, and it is a real one: it has been checked to fail both with the overlay displaced 300 px and with no compositor.
- **Stop Sharing badge stuck on** — usually means a helper subprocess was orphaned by a stop/restart race. The screen-share server has a restart lock for this; if you touch capture restart, preserve the await-pending-restart-then-teardown ordering. This includes the mid-share "Change Source…" path: `TailscaleScreenShareServer.changeSource(filterData:)` swaps the cached selection and rides the same tracked restart — never spawn a helper directly.

## CI/CD

**Shared build definitions.** The per-OS app build is defined ONCE and called
from both its per-push and its release workflow, so a build fix lands in one
place: `.github/workflows/app-macos.yml` (release.yml, for both the release and the
`build:notarized` PR build),
`app-windows.yml` (windows-build.yml + release.yml), `app-linux.yml`
(build.yml's `linux-app-arm64` + release.yml's arm64 packaging). Under
them, `.github/actions/bootstrap` is the composite action every build job runs
after checkout: apply the TailscaleKit patch series, materialize the symlinks
Windows checkouts mangle, set up Go from the submodule's `go.mod`, and produce
(or restore from cache) `libtailscale.a` for the target — `host`,
`macos-universal`, `windows-amd64` or `windows-arm64`, staging the Windows ones
as both `libtailscale.a` and `tailscale.lib`. It deliberately does NOT own the
checkout (a local action can only be resolved once the repo is on disk) or
`git config core.symlinks` (must precede the checkout).

Two rules when touching any of this:

- **Caches are keyed on the matrix/arch dimension.** `libtailscale.a`,
  `Apps/windows/.build` and `Apps/linux/.build` all carry `runner.arch` (or
  the equivalent input) in their keys. An x64 object tree restored into an
  arm64 build is a bug this repo has already shipped once.
- **`use_cache` / `cache` is POLICY, not convenience.** CI passes true; every
  release workflow passes FALSE, so a shipped artifact is compiled from source
  on the runner that ships it. Sharing one definition is not sharing one
  policy.
- **`windows-build.yml`'s `paths:` list must contain every input to any of its
  jobs** — including `.github/workflows/app-windows.yml` and
  `.github/actions/bootstrap/**`, since the build steps live there now. That
  list has been holed twice, and both times the symptom was a branch full of
  green checks while the last real Windows result was a failure several commits
  back.

Three workflows under `.github/workflows/` (plus a docs-deploy workflow):

- **Build** — runs `make build` + `make test` on every PR and push to `main`. Skips doc-only changes. Uses `concurrency.cancel-in-progress` to drop superseded runs. Also in this workflow: the **`linux-packages` matrix** — six legs of one job, named `linux-protocol` / `linux-opus` / `linux-ffmpeg` / `linux-alsa` / `linux-x11-capture` / `linux-tailscalekit` so the check names are unchanged, with `fail-fast: false` so one broken gate doesn't cancel the others. The legs: a **`linux-protocol` leg** (Ubuntu, `swift:6.3-noble` container: `swift test --package-path Packages/TailscreenKit` — the required portability gate for the protocol package; needs the submodule + patches for the transport tier's header and apt `libopus-dev`/`pkg-config` for the `TailscreenAudio` tier, but no Go build), a **`linux-tailscalekit` leg** (same container + apt Go: builds the patched libtailscale c-archive and runs the TailscaleKit unit tests on Linux — the transport-portability gate), a **`linux-opus` leg** (same container + apt `libopus-dev`: builds `OpusKit` and runs its encode/decode round-trip tests — the audio-codec-portability gate for the Opus-only decision, `docs/porting-plan.md` #6), a **`linux-ffmpeg` leg** (same container + apt `libavcodec-dev`: builds `FFmpegKit` and runs its H.264 decode/encode + AVCC↔Annex-B tests — the video-codec-portability gate for the Linux/Windows viewer *and* the Linux sharer's encoder), a **`linux-x11-capture` leg** (same container + apt `libxcb1-dev libxcb-shm0-dev xvfb`: builds `X11CaptureKit` and runs its colour-conversion tests plus, under `xvfb-run`, live root-window capture — the screen-capture-portability gate; X11 capture is the one capture path that *can* run headlessly, which is why it landed before the ScreenCast portal), a **`linux-alsa` leg** (same container + apt `libasound2-dev`: builds `ALSAKit` and runs its PCM-playback tests against ALSA's `null` device — the audio-playback-portability gate for the Linux viewer's audio output), a **`linux-xtest` leg** (same container + apt `libxtst-dev xvfb`: the input-injection-portability gate for the Linux sharer's remote control — the injector's unit tests through an inject-nothing seam, `xtest-probe --audit-keysyms` checking every `X11KeyCodeMapping` row against Xlib's own tables, and `--live-check` doing real XTEST injection against Xvfb and reading the pointer back; the three cover different things and all three regress silently), a **`linux-viewer` job** (same container + the A/V dev libs + libxcb/Xvfb + the libtailscale Go c-archive: `xvfb-run … swift test --package-path Packages/TailscreenLinuxBackends` — the platform-backend integration gate that runs `PipelineIntegrationTests` (real H.264 encode → RTP → `ViewerSession` → FFmpeg decode → collecting sinks) AND `CaptureEncoderTests` (real X11 capture → libavcodec encode → decode, through the `CaptureEncoding` seam — it needs the `xvfb-run` `$DISPLAY` or it self-skips) AND link-checks `TailscreenViewerTsnet` on Linux; a live tsnet run stays local-only), a **`linux-app` job** (which also caches `Apps/linux/.build` and `Apps/windows/.build` — those two swift-cross-ui compiles used to set the whole workflow's wall clock; same container + apt GTK4 / gobject-introspection / epoxy / Mesa software-GL / Xvfb: builds the native GTK desktop viewer `Apps/linux` — swift-cross-ui chrome + a downstream `GtkVideoView` hosting a `GtkGLArea` with an OpenGL BT.709 YUV→RGB renderer — and runs its headless GL YUV-readback render self-test under Xvfb, **plus the annotation-overlay self-test** (`--overlay-self-test`, on a second Xvfb with `xcompmgr`: draws a red stroke on the sharer's overlay, reads the screen back through X11 capture, and asserts the chroma — the compositor is required, since the overlay deliberately refuses to exist without one); the live tsnet leg is local-only, see `docs/linux-viewer-gtk-plan.md`), a **`linux-app-arm64` job** (defined in `app-linux.yml`, shared with release.yml's arm64 packaging; GitHub's free `ubuntu-24.04-arm` runner + the same multi-arch `swift:6.3-noble` container: builds the linux/arm64 libtailscale c-archive and the GTK app in release config, gates it on the same Xvfb GL render self-test, and uploads a `tailscreen-linux-arm64.tar.gz` artifact — the arm64 leg is a hard gate, not compile-only; the arm64 AppImage lives in the release workflow (aarch64 linuxdeploy/appimagetool)), a **`build-release` job** (`swift build -c release` compile check, required — release-config breaks used to surface only on published releases) and a **diff-coverage gate** (`scripts/diff-coverage.sh`: lcov `DA:` records joined against `git diff -U0 origin/main...HEAD` changed lines in `Sources/*.swift`, fails under 70 % coverage of changed executable lines; currently `continue-on-error: true` with the same flip-to-required TODO convention as the `format` job).- **Soak** — nightly (`cron: 17 3 * * *`) + `workflow_dispatch`: runs `SoakTests` with `TAILSCREEN_SOAK=1` (the `ParserFuzzHarness` at ~50× PR budget plus the seeded `LossyChannel` impairment matrix). Deterministic — a red nightly names its reproducing seed/configuration.
- **Release** — fires when a GitHub release is **published**. Cross-builds `libtailscale.a` for `arm64` + `amd64`, lipo-merges, then `swift build -c release --arch arm64 --arch x86_64` for a universal Mach-O. Wraps it in `Tailscreen.app`, codesigns with a Developer ID identity, notarizes via `notarytool`, staples, and uploads the zipped `.app` + `checksums.txt` to the release. Signing + notarization run only when **all** of the Apple secrets (`APPLE_DEVELOPER_ID_CERT_P12`, `APPLE_DEVELOPER_ID_CERT_PASSWORD`, `APPLE_NOTARY_API_KEY_P8`, `APPLE_NOTARY_API_KEY_ID`, `APPLE_NOTARY_API_ISSUER_ID`) are set; otherwise an unsigned `.app` is uploaded with a warning. The build itself lives in the shared `app-macos.yml`, called by both this workflow and `pr-notarized-build.yml`; it runs a **"Stamp the build"** step before compiling that rewrites `BuildInfo.commit` (`Apps/macOS/Sources/BuildInfo.swift`, the value Settings → About's Build row shows) with the short SHA, and fails the job if the `sed` didn't take rather than shipping an app that calls itself a local `dev` build. Same trick, same reason as the Windows app's stamp. The Homebrew tap repo owns cask formatting. **One workflow, every platform.** `release.yml` fires on three triggers — release published / an on-demand PR label / `workflow_dispatch` against a tag — derives the tag, version and four-part MSIX Identity Version ONCE in a `version` job, and fans out to a job per deliverable: **macos** (the shared `app-macos.yml`, for BOTH the release and the `build:notarized` PR build — the latter absorbed from the retired pr-notarized-build.yml, since a signed+notarized .app is the only way to exercise UNUserNotificationCenter / TCC / Gatekeeper), **linux** (a matrix over x64/arm64 through the shared `app-linux.yml` — literally the same definition as CI's `linux-app-arm64` gate — producing an AppImage and a tarball per arch) plus **linux-upload** (a matrixed follow-on non-container job, because `gh` isn't in the swift container), and **windows** (both arches through the shared `app-windows.yml`, uploading a zip + a **self-signed** MSIX per arch — SignPath replaces the signing step before winget submission; manifest templates in `Apps/windows/packaging/winget/`). The PR labels are `build-linux-package`, `build-windows-package` and `build:notarized`, each platform's jobs gate on their own, and a shared `unlabel` job removes whichever fired so re-adding it rebuilds (GitHub does not re-fire `labeled` for a label already present). There is deliberately NO `concurrency:` block: `pull_request: [labeled]` fires once per label, so adding both labels yields two runs of this workflow that each do half the work, and grouping them would let one cancel the other — the bug already fixed twice elsewhere in this repo.

## Git workflow notes

- `.gitmodules` pins `Packages/TailscaleKit/upstream/libtailscale` to `tailscale/libtailscale.git` (`ignore = dirty`).
- After cloning: `git submodule update --init --recursive`.
- `.gitignore` excludes `.build/`, `.swiftpm/`, `Package.resolved`, the built `Tailscreen` binary, and `.envrc`.
- AI sessions develop on a designated `claude/...` branch — **do not push to `main`**. The active branch is named in the per-session prompt.
- License: MIT; upstream `libtailscale` is BSD-3-Clause.
