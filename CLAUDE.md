# CLAUDE.md

Guidance for Claude (and other AI assistants) working in this repo. Keep it accurate — if you change the build, layout, or protocol, update this file in the same commit.

## Project

**Tailscreen** is a macOS 15+ menubar app for low-latency, encrypted peer-to-peer screen sharing over Tailscale. It uses tsnet ephemeral nodes (no manual device registration), captures via ScreenCaptureKit, encodes H.264/HEVC with VideoToolbox, and renders with Metal. SwiftPM only — no Xcode project.

## Tech stack

- **Swift 6** with strict concurrency (`@MainActor`, `Sendable`).
- **macOS 15.2 (Sequoia)** deployment target. Not iOS. The 15.2 floor (vs. 15.0) is dictated by the `SCContentFilter.includedDisplays` / `includedWindows` / `includedApplications` getters the picker-helper uses to extract primitives.
- **Go 1.21+** required at build time to compile `libtailscale.a` (the C archive that TailscaleKit wraps).
- **SwiftUI** + `MenuBarExtra`, **ScreenCaptureKit**, **VideoToolbox**, **Metal** (`CAMetalLayer`).
- **TailscaleKit** consumed as a local SwiftPM package (`./TailscaleKitPackage`).

Runtime needs: Screen Recording permission, and either interactive Tailscale login or `TAILSCREEN_TS_AUTHKEY` (+ optional `TAILSCREEN_TS_CONTROL_URL`).

## Repository layout

```
tailscreen/
├── Sources/                    # Tailscreen executable (Swift)
├── Tests/TailscreenTests/      # Unit + connectivity tests
├── TailscaleKitPackage/        # Local SwiftPM dep wrapping libtailscale
│   ├── upstream/libtailscale/  # Git submodule (tailscale/libtailscale)
│   ├── Sources/  lib/  include/   # Symlinks into upstream
│   ├── Patches/                # .patch files applied to upstream Swift
│   ├── Modules/libtailscale/   # Module map for the C library
│   └── libtailscale.pc         # pkg-config file (used via PKG_CONFIG_PATH)
├── e2e/docker-compose.yml      # Local headscale control plane (port 8080)
├── scripts/e2e-{up,down,test}.sh
├── .github/workflows/
├── Package.swift
├── Makefile                    # Top-level build entry
└── test-local.sh               # Multi-instance local launcher
```

Use `rg` to find specific files; the layout above is enough orientation.

## Build & run

Always go through `make` — the root Makefile sets `PKG_CONFIG_PATH=$(CURDIR)/TailscaleKitPackage` so SwiftPM's `systemLibrary` target finds `libtailscale.pc`, which in turn supplies the `-L` flag for `libtailscale.a`.

```bash
make build         # builds libtailscale.a, then `swift build`
make run           # build + run debug binary
make release       # swift build -c release   → .build/release/Tailscreen
make install       # release + copy to ~/bin/Tailscreen
make clean         # swift package clean + rm .build + clean TailscaleKitPackage
make test          # swift test (after libtailscale)
make e2e-up        # start local headscale (Docker)
make e2e-down      # tear down headscale + volume
make test-e2e      # one-shot: e2e-up → swift test --filter TailscaleConnectivityTests → e2e-down
```

Running bare `swift build` before `make tailscale` will fail to link — you need `libtailscale.a` first.

First build downloads Go modules; **network access required**.

### TailscaleKit submodule

`TailscaleKitPackage/upstream/libtailscale` is pinned in `.gitmodules` (`ignore = dirty`). After a fresh clone, run `git submodule update --init --recursive` (or clone with `--recurse-submodules`).

Patches in `TailscaleKitPackage/Patches/*.patch` are applied on top of the upstream Swift sources. They add things like a `Foundation` import, glue imports for C-bridge types, `send`/`receive` on connections, public `logout`, listener poll-timeout handling, and the `tsnet ListenPacket` / `PacketListener` Swift wrapper used by the UDP video path. **Do not edit `TailscaleKitPackage/Sources/`** — those are symlinks into the submodule. Add or modify a patch instead, then re-run `make tailscale`.

## Testing

### Unit tests
```bash
make test
# or: PKG_CONFIG_PATH="$(pwd)/TailscaleKitPackage" swift test
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

**These tsnet suites can't run on CI.** Tried on `macos-latest` via the native script: headscale came up healthy, but the first tsnet `node.up()` hung — GitHub's hosted macOS runner sandbox doesn't let the userspace-WireGuard handshake / DERP-STUN (`:3478/udp`) complete, and `node.up()` has no internal timeout. So anything that brings up a tsnet node (`TailscaleConnectivityTests` and all the screen-share E2E suites) is local-only. Only the pure-logic suites (`AdaptiveBitrateTests`, `VideoCodecTests`, `VoiceChannelTests`, etc.) run on CI.

Connectivity tests skip or fail without an auth key — that's expected.

### Local screen-share E2E (LOCAL ONLY)

These test surfaces exercise the screen-share pipeline beyond what GitHub Actions can run — its macOS runners can't grant Screen Recording TCC, can't host a real display, and `replayd`/`SCStream` won't come up. Most run over local-headscale tsnet with the server in `filterData: nil` mode (no capture-helper), so they're headless and need no Screen Recording permission.

1. **`ScreenShareSyntheticFramesTests`** — server (no helper) + real client over local-headscale tsnet, pre-encoded AVCC injected into the broadcast path. Asserts on `client.onDecodedFrameForTesting` (decode signal — the renderer's display-link render path needs an on-screen view, which xctest lacks). CI-eligible (skips if VideoToolbox produces no output, e.g. virtualized runners).
2. **`ScreenShareCaptureHelperTests`** — full pipeline including the real `--capture-helper` subprocess against the main display, hosted in a real on-screen `NSWindow` so the Metal **render** path runs and `renderer.onVideoSizeChanged` fires. Jiggles the cursor to keep ScreenCaptureKit delivering frames (a static screen starves the encoder). Local-only — self-skips on `CI` / `GITHUB_ACTIONS`. First run pops macOS's Screen Recording permission prompt on `.build/debug/Tailscreen`; subsequent runs are unattended.
3. **`ScreenShareFanoutTests`** — two viewers on one server: asserts video fan-out (both decode one broadcast) and audio relay (one viewer's RTP reaches the sharer locally **and** is relayed to the other viewer, gated by the server-assigned SSRC).
4. **`ScreenShareControlChannelTests`** — viewer→sharer control paths: annotation op over the TCP back-channel reaches `server.onAnnotationReceived`; a viewer PLI is recorded (observed via the test-only `onPLIRecordedForTesting` seam, since no helper is attached to act on the keyframe request).
5. **`ScreenShareRequestToShareTests`** — two raw tsnet nodes: one sends `TailscreenMetadataService.sendRequestToShare`, the other's `TailscreenControlListener.onRequestToShare` fires. No UI/notifications.
6. **`PickerHelperSmokeTests`** — verifies the `--picker-helper` `TAILSCREEN_AUTOSHARE_DISPLAY=1` short-circuit (no UI; always runs locally). A second test exercises the full picker-UI lifecycle and SIGTERM path — that one pops the real picker on screen for ~2 s and is **opt-in**: set `TAILSCREEN_RUN_PICKER_LIFECYCLE_TEST=1` to enable.

`AdaptiveBitrateTests` is a pure unit test (no tsnet) covering `TailscaleScreenShareServer.nextAdaptiveBitrate` — the loss/recovery decision math and asymmetric hysteresis extracted from the sweep loop. An E2E version isn't viable: the live sweep intentionally no-ops without a capture-helper attached.

Test-only seams added for the above: `TailscaleScreenShareClient.onDecodedFrameForTesting`, `.sendPLIForTesting()`; `TailscaleScreenShareServer.onPLIRecordedForTesting`, `.injectSyntheticParameters`, `.broadcastForTesting`, `.nextAdaptiveBitrate`. Shared bring-up helpers live in `TailscreenE2EHelpers.swift` (`encodeSyntheticAUs`, multi-dir `makeStateDirs`).

```bash
make test-e2e-local     # XCTest suites above, under local headscale
make test-e2e-harness   # two real Tailscreen processes, asserted by log marker
```

Four new env-var test affordances:

| Env var | Read by | Effect |
|---------|---------|--------|
| `TAILSCREEN_AUTOSHARE_DISPLAY=1` | `--picker-helper` subprocess | Skip the interactive picker; emit a synthetic main-display `PickerSelection` and exit. |
| `TAILSCREEN_AUTOSTART_SHARE=1` | Main process (`AppState.init`) | Once signed in, automatically invoke `presentNativePicker()`. Pair with `TAILSCREEN_AUTOSHARE_DISPLAY=1`. |
| `TAILSCREEN_AUTOCONNECT_TO=<prefix>` | Main process (`AppState.init`) | Once signed in, discover peers and connect to the first one whose hostname starts with `<prefix>`. |
| `TAILSCREEN_HELPER_EXE=<path>` | `HelperScreenCapture` / `PickerHelperClient` | Override `Bundle.main.executableURL` for helper spawns. Only used by XCTests (under xctest, `Bundle.main` points at the test harness, not Tailscreen). |
| `TAILSCREEN_RUN_PICKER_LIFECYCLE_TEST=1` | `PickerHelperSmokeTests` | Opt in to the picker-UI lifecycle test that pops the real picker on screen for ~2 s before SIGTERM. Skipped by default to keep `make test-e2e-local` non-interactive. |

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
 │        ├─ VoiceChannel (PCM ↔ AAC ↔ RTP, bidi over UDP/7447)
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

## Network protocol — port 7447 (TCP **and** UDP)

- **Video — UDP RTP.** AVCC NAL units; parameter sets (SPS+PPS for H.264, VPS+SPS+PPS for HEVC) in-band on every keyframe; PLI-driven keyframe roughly every 2 s. No buffering; UDP loss is accepted. The viewer auto-detects the codec from the RTP payload type (`97` HEVC, `96` H.264) — no out-of-band negotiation.
- **Audio — UDP RTP, separate SSRC space.** AAC-LC, mono, 48 kHz, one access unit per packet. Bidi sharer↔viewer plus viewer-to-viewer relay (the server forwards inbound viewer audio byte-for-byte after validating the source-assigned SSRC).
- **Annotations / control — TCP, framed.** `[type:1][len:4 BE][payload:N]`, payload is JSON-encoded. TCP gives reliable delivery so strokes don't drop.
- **Metadata — TCP request/response on the same port.** Share name, resolution, request-to-share prompts.
- **Discovery probe.** Parallel TCP/7447 probe across the tailnet to identify Tailscreen instances.

## Capture-helper IPC

Capture and encoding run in a child process spawned per share — `Tailscreen --capture-helper`. Process death is the only reliable way to clear `replayd`'s per-bundle slot, so isolating `SCStream` + VideoToolbox in a child means "Stop Sharing" always works.

- **Spawn.** The parent `Process()`-execs the same binary with `--capture-helper`. Stdin and stdout are pipes; stderr streams through to the parent's terminal.
- **Startup.** The helper waits on stdin for a framed `contentFilter` message — payload is a JSON-encoded `PickerSelection` (display / window / bundle IDs) from the picker-helper — before bringing the SCStream up. The helper resolves those IDs against `SCShareableContent` (legal inside the helper, never in the main process) and rebuilds the filter on its side. There's no other entry point: every share routes through the picker.
- **Wire.** Framed binary — `[type:1][len:4 BE][payload:N]`. Message types: encoded access unit (AVCC), parameter sets (H.264 SPS/PPS or HEVC VPS/SPS/PPS), preview thumbnail, log line, fatal, user-stopped; control commands request-keyframe, set-bitrate, content-filter, shutdown.
- **Lifecycle.** The helper writes encoded AUs directly from the encoder thread to preserve order. On Control Center "Stop", the helper exits 0 with a `userStopped` message and the parent tears the share down quietly. Any other helper exit triggers up to 3 auto-restarts within a 30 s window before giving up. Restart re-spawns against the same cached selection — the JSON bytes are reusable across helper PIDs because each helper re-resolves the IDs independently.

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
linkerSettings: [.unsafeFlags(["-L", "TailscaleKitPackage/lib"])]
```

Never make this absolute — it breaks portability and CI. Both the `Tailscreen` target and the `TailscreenTests` target carry this flag.

## Localization

User-facing strings are localized through SwiftPM resources. `Package.swift` sets `defaultLocalization: "en"`, and the base catalog lives at `Sources/Resources/en.lproj/Localizable.strings` (alongside the unlocalized PDF/SVG assets already under `Resources/`, both picked up by the existing `.process("Resources")`).

- **Route every user-facing string through `L(_:)`** (defined in `Sources/Localization.swift`). It calls `String(localized:bundle: .module)` — the `bundle: .module` part is essential. SwiftUI's implicit `LocalizedStringKey` lookups (`Text("…")`, `Button("…")`) and a bare `String(localized:)` both default to `Bundle.main`, which in a SwiftPM executable does **not** contain the `.lproj` resources. Those live in `Bundle.module`.
- **SwiftUI:** wrap as `Text(L("…"))`. For `Button`/`Toggle`/`Picker`/`Section`/`Label`/`.help`/`.accessibilityLabel`/`.accessibilityHint`, pass `L("…")` (a plain already-localized `String`, so no double lookup). **AppKit:** `NSMenuItem(title: L("…"))`, `alert.addButton(withTitle: L("…"))`, `content.title = L("…")`, etc.
- **Keys are the English source text** (base-language-as-key). Interpolation works: `L("Viewing \(host)")` looks up `"Viewing %@"` (Int → `%lld`). Keep keys in the catalog byte-for-byte in sync with call sites.
- **Don't localize** log lines (`TSLogger`/`print`), error codes (`TS-…`), key-equivalent glyphs (`⌘Q`), SF Symbol names, or brand nouns ("Tailscreen", "Tailscale").
- **To add a language:** copy `en.lproj/Localizable.strings` to `<lang>.lproj/Localizable.strings` (e.g. `sv.lproj`) under `Sources/Resources/` and translate the values only. No code changes.

## Common pitfalls

- **`swift build` fails with linker errors** — you skipped `make tailscale`. The Go build emits `libtailscale.a`; without it nothing links.
- **Two local instances see no peers** — both processes are sharing one Tailscale state dir. Use `./test-local.sh` (or set `TAILSCREEN_INSTANCE` manually).
- **Editing `TailscaleKitPackage/Sources/` directly** — those paths are symlinks into the upstream submodule. Add a patch under `TailscaleKitPackage/Patches/` instead.
- **Port 7447 is hardcoded** across the discovery, server, client, and metadata paths. If you make it configurable, search for `7447` and update everywhere it appears.
- **Auth flow needs an active node** — interactive login only works after `Start Sharing` or `Connect to…` has initialized the tsnet node.
- **CI uses submodules.** Workflows already pass `submodules: recursive`; if you add a new workflow that builds, do the same.
- **Don't call `SCShareableContent` from the main process.** It registers the parent with `replayd`, and the helper child's subsequent `SCStream` then fails with "application connection being interrupted". Never call `SCShareableContent` in the parent — and don't reintroduce a parent-side Screen Recording permission gate either. The native `SCContentSharingPicker` (running in the picker-helper) drives the TCC prompt on first use; preflighting from the parent is unnecessary and was removed.
- **Don't present `SCContentSharingPicker` from the main process either.** Same family of APIs, same defensive isolation — spawn `--picker-helper` instead. The picker subprocess exits the moment the user picks, so its XPC handles never live alongside the long-running main process.
- **Don't deserialize an `SCContentFilter` in the main process.** The decoded filter retains XPC handles to system services; the unarchive happens only inside the capture-helper.
- **Don't add SCStream lifecycle to the main process.** All capture lives in the helper subprocess. The main-process screen-share server only spawns the helper and broadcasts what comes back.
- **Stop Sharing badge stuck on** — usually means a helper subprocess was orphaned by a stop/restart race. The screen-share server has a restart lock for this; if you touch capture restart, preserve the await-pending-restart-then-teardown ordering.

## CI/CD

Two workflows under `.github/workflows/` (plus a docs-deploy workflow):

- **Build** — runs `make build` + `make test` on every PR and push to `main`. Skips doc-only changes. Uses `concurrency.cancel-in-progress` to drop superseded runs.
- **Release** — fires when a GitHub release is **published**. Cross-builds `libtailscale.a` for `arm64` + `amd64`, lipo-merges, then `swift build -c release --arch arm64 --arch x86_64` for a universal Mach-O. Wraps it in `Tailscreen.app`, codesigns with a Developer ID identity, notarizes via `notarytool`, staples, and uploads the zipped `.app` + `checksums.txt` to the release. Signing + notarization run only when **all** of the Apple secrets (`APPLE_DEVELOPER_ID_CERT_P12`, `APPLE_DEVELOPER_ID_CERT_PASSWORD`, `APPLE_NOTARY_API_KEY_P8`, `APPLE_NOTARY_API_KEY_ID`, `APPLE_NOTARY_API_ISSUER_ID`) are set; otherwise an unsigned `.app` is uploaded with a warning. The Homebrew tap repo owns cask formatting.

## Git workflow notes

- `.gitmodules` pins `TailscaleKitPackage/upstream/libtailscale` to `tailscale/libtailscale.git` (`ignore = dirty`).
- After cloning: `git submodule update --init --recursive`.
- `.gitignore` excludes `.build/`, `.swiftpm/`, `Package.resolved`, the built `Tailscreen` binary, and `.envrc`.
- AI sessions develop on a designated `claude/...` branch — **do not push to `main`**. The active branch is named in the per-session prompt.
- License: MIT; upstream `libtailscale` is BSD-3-Clause.
