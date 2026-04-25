# CLAUDE.md

Guidance for Claude (and other AI assistants) working in this repo. Keep it accurate — if you change the build, layout, or protocol, update this file in the same commit.

## Project

**Tailscreen** is a macOS 15+ menubar app for low-latency, encrypted peer-to-peer screen sharing over Tailscale. It uses tsnet ephemeral nodes (no manual device registration), captures via ScreenCaptureKit, encodes H.264 with VideoToolbox, and renders with Metal. SwiftPM only — no Xcode project.

## Tech stack

- **Swift 6.0** with strict concurrency (`@MainActor`, `Sendable`).
- **macOS 15.0 (Sequoia)** deployment target. Not iOS.
- **Go 1.21+** required at build time to compile `libtailscale.a` (the C archive that TailscaleKit wraps).
- **SwiftUI** + `MenuBarExtra`, **ScreenCaptureKit**, **VideoToolbox**, **Metal** (`CAMetalLayer`).
- **TailscaleKit** consumed as a local SwiftPM package (`./TailscaleKitPackage`).

Runtime needs: Screen Recording permission, and either interactive Tailscale login or `TAILSCREEN_TS_AUTHKEY` (+ optional `TAILSCREEN_TS_CONTROL_URL`).

## Repository layout

```
tailscreen/
├── Sources/                    # Tailscreen executable (Swift)
├── Tests/TailscreenTests/      # Unit + connectivity tests
├── Examples/                   # Standalone API usage demo
├── TailscaleKitPackage/        # Local SwiftPM dep wrapping libtailscale
│   ├── upstream/libtailscale/  # Git submodule (tailscale/libtailscale)
│   ├── Sources/  lib/  include/   # Symlinks into upstream
│   ├── Patches/                # 16 .patch files applied to upstream Swift
│   ├── Modules/libtailscale/   # Module map for the C library
│   └── libtailscale.pc         # pkg-config file (used via PKG_CONFIG_PATH)
├── e2e/docker-compose.yml      # Local headscale control plane (port 8080)
├── scripts/e2e-{up,down,test}.sh
├── .github/workflows/{build,release}.yml
├── Package.swift
├── Makefile                    # Top-level build entry
└── test-local.sh               # Multi-instance local launcher
```

### Sources/ (26 files)

| File | Role |
|------|------|
| `TailscreenApp.swift` | `@main` entry; menubar lifecycle |
| `AppState.swift` | Central `@MainActor` coordinator (sharing, connecting, peers, displays) |
| `MenuBarView.swift` | All SwiftUI views (menus, sheets, alerts) |
| `AppMenu.swift` | Native `NSMenu` setup (File → Disconnect, etc.) |
| `TailscaleScreenShareServer.swift` | Server: capture → encode → RTP fan-out |
| `TailscaleScreenShareClient.swift` | Client: RTP recv → decode → render; sends annotations back |
| `TailscalePeerDiscovery.swift` | LocalAPI peer enumeration + parallel TCP/7447 probing |
| `TailscaleIPNWatcher.swift` | IPN-bus watcher for live online/offline events |
| `TailscaleAuth.swift` | Auth state + browser-based interactive login |
| `TailscaleConnectionExtension.swift` | Helpers on TailscaleKit types |
| `TailscreenMetadata.swift` | Share metadata + request-to-share protocol |
| `TailscreenInstance.swift` | `TAILSCREEN_INSTANCE` env handling for local multi-process testing |
| `ScreenShareProtocol.swift` | Wire format for annotation back-channel |
| `RTPPacket.swift` | H.264 RTP packetize / depacketize (RFC 3984), SPS/PPS extraction |
| `VideoEncoder.swift` | VideoToolbox H.264 encode (low-latency, no reordering) |
| `VideoDecoder.swift` | VideoToolbox H.264 decode |
| `ScreenCapture.swift` | ScreenCaptureKit setup (60 fps, Retina 2x) |
| `MetalViewerRenderer.swift` | `CAMetalLayer` rendering for the viewer window |
| `Annotation.swift` | `AnnotationOp` data + stroke ops |
| `DrawingOverlayView.swift` | Annotation drawing UI |
| `SharerOverlayWindow.swift` | `NSWindow` showing inbound annotations on the sharer |
| `ViewerCommands.swift` | Annotation/control command types and serialization |
| `ViewerToolbar.swift` | Viewer window toolbar (brightness, magnifier, etc.) |
| `NetworkHelper.swift` | Socket/network utilities |
| `ScreenShareClient.swift` | Legacy non-Tailscale client (kept for reference) |
| `ScreenShareServer.swift` | Legacy non-Tailscale server (kept for reference) |

### Tests/TailscreenTests/

| File | Notes |
|------|-------|
| `RTPPacketTests.swift` | Packetize/depacketize roundtrip |
| `ScreenShareProtocolTests.swift` | TCP frame parsing |
| `VideoCodecTests.swift` | Encoder/decoder roundtrip |
| `TailscaleConnectivityTests.swift` | E2E: two ephemeral nodes in-process; **needs** `TAILSCREEN_TS_AUTHKEY` (+ optional `TAILSCREEN_TS_CONTROL_URL`). Skipped/failing without those. |

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

First build downloads Go modules; **network access required**. CI uses `actions/setup-go@v5` with Go 1.21.

### TailscaleKit submodule

`TailscaleKitPackage/upstream/libtailscale` is pinned in `.gitmodules` (`ignore = dirty`). After a fresh clone, run `git submodule update --init --recursive` (or clone with `--recurse-submodules`).

Patches in `TailscaleKitPackage/Patches/*.patch` (16 files) are applied on top of the upstream Swift sources. They add: `Foundation` import, glue `import` lines for C-bridge types, `send`/`receive` on connections, public `logout`, listener poll-timeout handling, and the `tsnet ListenPacket` / `PacketListener` Swift wrapper used by the UDP video path. **Do not edit `TailscaleKitPackage/Sources/`** — those are symlinks into the submodule. Add or modify a patch instead, then re-run `make tailscale`.

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
   `scripts/e2e-up.sh` boots `e2e/docker-compose.yml` (headscale 0.26.1 on `localhost:8080`), creates user `tailscreen-test`, and mints a reusable ephemeral pre-auth key.

2. **Real tailnet:** export your own `TAILSCREEN_TS_AUTHKEY` from the Tailscale admin console and run `swift test`.

### Local manual testing — multiple instances on one Mac

```bash
./test-local.sh           # 2 instances (default)
./test-local.sh 3         # N instances
```

Each child gets `TAILSCREEN_INSTANCE=<i>`, which `TailscreenInstance.swift` uses to suffix the Tailscale state directory and hostname (e.g. `wisp-1`, `wisp-2`). Without it, two processes share `~/Library/Application Support/Tailscreen/tailscale`, reuse the same machine key, and the browser sees zero peers (it's looking at its own node).

Merged stdout/stderr lands in `/tmp/tailscreen-merged.log` (override with `TAILSCREEN_LOG`). Ctrl-C kills the whole process group.

Memory-debug modes (set before invoking the script):

| Env var | Effect |
|---------|--------|
| `TAILSCREEN_DEBUG_ZOMBIES=1` | `NSZombieEnabled` + malloc stack logging — over-releases log instead of crashing |
| `TAILSCREEN_DEBUG_ASAN=1` | Sets `ASAN_OPTIONS`; **also rebuild with** `swift build -Xswiftc -sanitize=address` |
| `TAILSCREEN_DEBUG_GMALLOC=1` | libgmalloc — known to break ScreenCaptureKit's XPC; prefer Instruments' Zombies template |

## Architecture & data flow

```
TailscreenApp (@main)
  └─ AppState (@MainActor)
       ├─ TailscaleScreenShareServer
       │    └─ ScreenCapture → VideoEncoder → RTPPacket → UDP/7447 (TailscaleNode.listenPacket)
       │       + TCP/7447 (annotations + metadata)
       ├─ TailscaleScreenShareClient
       │    └─ UDP/7447 → RTP depacketize → VideoDecoder → MetalViewerRenderer
       │       + TCP/7447 (annotations out)
       ├─ TailscalePeerDiscovery   ── LocalAPI + TCP probe
       ├─ TailscaleIPNWatcher      ── IPN bus subscription
       ├─ TailscaleAuth            ── browser-based login
       └─ TailscreenMetadataService ── share name, resolution, request-to-share
```

The viewer window (`NSWindow` + `MetalViewerRenderer`) is held for the process lifetime to avoid an autoreleasepool teardown race with VideoToolbox/Metal on disconnect.

## Network protocol — port 7447 (TCP **and** UDP)

- **Video — UDP RTP (RFC 3984).** AVCC NAL units; SPS/PPS in-band on keyframes; PLI-driven keyframe roughly every 2 s. No buffering; UDP loss is accepted. Packetizer/depacketizer in `RTPPacket.swift`.
- **Annotations / control — TCP, framed.** `[type:1][len:4 BE][payload:N]`, payload is JSON-encoded `AnnotationOp`. Defined in `ScreenShareProtocol.swift`. TCP gives reliable delivery so strokes don't drop.
- **Metadata — TCP request/response on the same port.** `TailscreenMetadataService` exchanges share name, resolution, and "request-to-share" prompts.
- **Discovery probe.** `TailscalePeerDiscovery` parallel-probes TCP/7447 across the tailnet to identify Tailscreen instances.

> Note: an older single-stream TCP framing `[size:4][keyframe:1][data:N]` exists in `ScreenShareServer.swift` / `ScreenShareClient.swift` (legacy, non-Tailscale path). The active Tailscale path is RTP/UDP for video plus the framed TCP control channel above. Don't confuse the two when editing.

## Swift 6 conventions used here

- `@MainActor` on all UI-touching state: `AppState`, `MenuBarView`, anywhere that constructs an `NSWindow`.
- `@unchecked Sendable` on networking classes that handle their own thread safety (`TailscaleScreenShareServer`, `TailscaleScreenShareClient`).
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

## Common pitfalls

- **`swift build` fails with linker errors** — you skipped `make tailscale`. The Go build emits `libtailscale.a`; without it nothing links.
- **Two local instances see no peers** — both processes are sharing one Tailscale state dir. Use `./test-local.sh` (or set `TAILSCREEN_INSTANCE` manually).
- **Editing `TailscaleKitPackage/Sources/` directly** — those paths are symlinks into the upstream submodule. Add a patch under `TailscaleKitPackage/Patches/` instead.
- **Port 7447 is hardcoded** in `TailscalePeerDiscovery`, `TailscaleScreenShareServer`, `TailscaleScreenShareClient`, and `TailscreenMetadataService`. If you ever make it configurable, change all four.
- **Auth flow needs an active node** — interactive login only works after `Start Sharing` or `Connect to…` has initialized the tsnet node.
- **CI uses submodules.** Workflows already pass `submodules: recursive`; if you add a new workflow that builds, do the same.

## CI/CD

- `.github/workflows/build.yml` — `macos-latest`, Go 1.21, on push to `main` and `claude/**` and PRs to `main`. Runs `make build` then `make test`.
- `.github/workflows/release.yml` — triggered when a GitHub release is **published** (or via `workflow_dispatch` with a tag input). Runs on `macos-15` (Apple Silicon; needs Swift 6 toolchain — `macos-14` ships Swift 5.10):
  - Cross-builds `libtailscale.a` for `arm64` and `amd64` (per-arch `GOARCH` + `CGO_CFLAGS=-arch …`), then `lipo`-merges into the symlink at `TailscaleKitPackage/lib/libtailscale.a`.
  - `swift build -c release --arch arm64 --arch x86_64` produces a universal Mach-O at `.build/apple/Products/Release/Tailscreen`.
  - Wraps it in `Tailscreen.app` with bundle id `se.middlemanagement.tailscreen`, `LSMinimumSystemVersion=15.0`, `LSUIElement=true`, version pulled from the release tag (`v1.2.3` → `1.2.3`).
  - Codesigns with a Developer ID Application identity loaded into a temp keychain, notarizes via `xcrun notarytool --wait` using an App Store Connect API key, and staples.
  - Zips with `ditto -c -k --keepParent` and uploads `Tailscreen-<tag>-macOS.zip` + `checksums.txt` to the triggering release with `gh release upload --clobber`.
  - No release-notes or cask generation here — the tap repo owns cask formatting.
  - Signing + notarization run only when **all** of these secrets are set: `APPLE_DEVELOPER_ID_CERT_P12` (base64 .p12), `APPLE_DEVELOPER_ID_CERT_PASSWORD`, `APPLE_NOTARY_API_KEY_P8` (base64 .p8), `APPLE_NOTARY_API_KEY_ID`, `APPLE_NOTARY_API_ISSUER_ID`. If any are missing, the workflow logs a warning and uploads an unsigned `.app` (useful for forks / dry runs).

## Git workflow notes

- `.gitmodules` pins `TailscaleKitPackage/upstream/libtailscale` to `tailscale/libtailscale.git` (`ignore = dirty`).
- After cloning: `git submodule update --init --recursive`.
- `.gitignore` excludes `.build/`, `.swiftpm/`, `Package.resolved`, the built `Tailscreen` binary, and `.envrc`.
- AI sessions develop on a designated `claude/...` branch — **do not push to `main`**. The active branch is named in the per-session prompt.
- License: MIT (per `README.md`); upstream `libtailscale` is BSD-3-Clause.

## Pointers for changes

- Touching the video pipeline → read `RTPPacket.swift`, `VideoEncoder.swift`, `VideoDecoder.swift`, `MetalViewerRenderer.swift` together.
- Touching annotations → `Annotation.swift`, `ScreenShareProtocol.swift`, `DrawingOverlayView.swift`, `SharerOverlayWindow.swift`, `ViewerCommands.swift`.
- Touching networking / discovery → `TailscaleScreenShareServer.swift`, `TailscaleScreenShareClient.swift`, `TailscalePeerDiscovery.swift`, `TailscaleIPNWatcher.swift`, `TailscreenMetadata.swift`.
- Touching UI/state → `AppState.swift`, `MenuBarView.swift`, `AppMenu.swift`, `ViewerToolbar.swift`.
- Touching the build → `Makefile`, `Package.swift`, `TailscaleKitPackage/Makefile`, `TailscaleKitPackage/Patches/`.
