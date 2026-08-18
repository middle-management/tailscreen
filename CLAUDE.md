# CLAUDE.md

Guidance for Claude (and other AI assistants) working in this repo. Keep it accurate — if you change the build, layout, or protocol, update this file (or the matching file under `.claude/rules/`) in the same commit.

## Project

**Tailscreen** is a low-latency, encrypted peer-to-peer screen-sharing app over Tailscale, with native apps for **macOS 15+** (`Apps/macOS`), **Linux** (`Apps/linux`, GTK4) and **Windows** (`Apps/windows`, WinUI) that all speak one wire protocol — any of them can view or share to any other (the Linux sharer captures X11 directly or a Wayland session via the ScreenCast portal, and injects remote control via XTEST; system-audio capture is macOS-only today). The macOS app is the reference implementation and most of this file describes it: the UI is a regular docked main window (sign-in, accounts, the peer list — the hub) plus a menubar item that acts as the sharer tool (share status, start/stop, mic/system-audio/drawing controls). Viewer approvals and remote-control requests render on **both** surfaces, sharing the same components, so a sharer never has to hop between them to answer a prompt. It uses tsnet ephemeral nodes (no manual device registration), captures via ScreenCaptureKit, encodes H.264/HEVC with VideoToolbox, and renders with Metal. SwiftPM only — no Xcode project.

## Tech stack

- **Swift 6** with strict concurrency (`@MainActor`, `Sendable`).
- **macOS 15.2 (Sequoia)** deployment target. Not iOS. The 15.2 floor (vs. 15.0) is dictated by the `SCContentFilter.includedDisplays` / `includedWindows` / `includedApplications` getters the picker-helper uses to extract primitives.
- **Go 1.21+** required at build time to compile `libtailscale.a` (the C archive that TailscaleKit wraps).
- **libopus** required at build time: the app links it (via `./Packages/OpusKit`'s `COpus` systemLibrary) for the Opus audio path. Install with `brew install opus` (macOS) / `apt install libopus-dev` (Linux); pkg-config resolves it.
- **SwiftUI** (`Window` main scene + `MenuBarExtra` sharer tool; the app runs at `.regular` activation policy — Dock icon, always-reachable menu bar), **ScreenCaptureKit**, **VideoToolbox**, **Metal** (`CAMetalLayer`).
- **TailscaleKit** consumed as a local SwiftPM package (`./Packages/TailscaleKit`); **OpusKit** likewise (`./Packages/OpusKit`).

Runtime needs: Screen Recording permission, and either interactive Tailscale login or `TAILSCREEN_TS_AUTHKEY` (+ optional `TAILSCREEN_TS_CONTROL_URL`).

## Repository layout

One directory is not Swift at all: **`sdk/go`** is the public Go implementation of the wire protocol (plus a `-buildmode=c-archive` build of it as `libtailscreen.a`), which `conformance/` runs the vectors against. Three runnable apps, each its own SwiftPM package: `Apps/macOS` (the primary), `Apps/linux` and `Apps/windows` (both swift-cross-ui — GTK4 and WinUI). Under `Packages/`, the ones whose role isn't obvious from the name: **TailscreenKit** is the portable Linux-buildable protocol + viewer + sharer core all three apps depend on; **TailscaleKit** wraps libtailscale (submodule + patches); **TailscreenHubUI** is the shared hub look for the two swift-cross-ui apps; **TailscreenL10n** is the string catalog all three apps share. The rest are platform backends — `X11CaptureKit`/`PortalCaptureKit`/`TailscreenSharerPortal`/`XTestInjectKit`/`X11HotkeyKit`/`GNotifyKit`/`ALSAKit`/`TailscreenLinuxBackends` on Linux, `WGCCaptureKit`/`SendInputKit`/`WinOverlayKit`/`WinHotkeyKit`/`WinNotifyKit`/`WASAPIKit`/`TailscreenSharerWGC` on Windows — or codec wrappers (`OpusKit`, `FFmpegKit`, `TailscreenVideoFFmpeg`).

**TailscreenL10n** is the string catalog — one `.lproj` set plus a portable
`L(_:)` — that all three apps and TailscreenHubUI read, so a string translated
once is translated everywhere.

Use `rg` to find specific files; the per-area rules files below carry the rest.

## Build & run

Always go through `make` (`make build`, `test`, `run`, `release`, …) — the root Makefile sets `PKG_CONFIG_PATH=$(CURDIR)/Packages/TailscaleKit` so SwiftPM's `systemLibrary` target finds `libtailscale.pc`, which in turn supplies the `-L` flag for `libtailscale.a`. Two targets whose purpose isn't obvious from the Makefile:

- `make test-protocol` — builds + smoke-tests the portable TailscreenKit package with no Apple frameworks. Also runs on Linux, and is how you reproduce a `linux-protocol` CI failure locally. It builds `libtailscale.a` first: the package's `TailscreenSharerTests` bundle links `TailscreenSharer` → `TailscaleKit`, so the archive is a link-time input even though no test calls tsnet.
- `make test-differential` — the Swift↔Go differential suite (`Packages/TailscreenDifferential`): the shipping Swift pipeline and the public Go SDK, built as `libtailscreen.a` and linked through the `CTailscreen` systemLibrary (resolved via `sdk/go/libtailscreen.pc` — the Makefile's `PKG_CONFIG_PATH` carries `sdk/go` for it), driven with identical seeded input and asserted identical at every step. A **separate** package on purpose: two Go c-archives cannot share one binary, and TailscreenKit's test executable already links `libtailscale.a`. Reproduces a `linux-differential` CI failure.
- `make test-conformance` — runs the protocol conformance vectors (`conformance/vectors/`) against **`sdk/go`**, the public Go SDK, which was written from `docs/spec.md` and shares no code with ours. Needs Go, nothing else. CI's `linux-conformance` leg runs this **plus** `cd sdk/go && go test ./...` **plus** `make libtailscreen-check` — reproduce all three before concluding a failure there is flaky. The Swift half of the same pair rides inside `make test-protocol`. Neighbours: `make fuzz-conformance` (coverage-guided fuzzing of the same parsers, off the PR path) and `make libtailscreen-check` (the SDK as a C static library — `-buildmode=c-archive`, same mechanism as `libtailscale.a` — plus the C smoke test that links it).
- `make test-l10n` — builds + tests the shared string catalog. Its suites scan **all four** source trees for `L("…")` keys the catalog is missing, so it is the only check on the GTK and WinUI apps' user-facing strings; reproduces a `linux-l10n` CI failure.
- `make test-e2e` — one-shot `e2e-up` → `swift test --filter TailscaleConnectivityTests` → `e2e-down` against a local headscale in Docker.

The app package lives in `Apps/macOS/` — bare `swift` commands for the app must run from that directory (from the repo root there is no manifest at all). And running `swift build` there before `make tailscale` will fail to link — you need `libtailscale.a` first.

First build downloads Go modules; **network access required**.

After a fresh clone: `git submodule update --init --recursive` (the libtailscale submodule).

## Protocol at a glance

Port **7447**, TCP **and** UDP. Video and audio are RTP over UDP (video PT 96 = H.264 / 97 = HEVC, audio PT 98 = voice / 99 = system audio; the viewer auto-detects, nothing is negotiated out of band). Loss recovery is layered FEC → NACK → PLI, capability-negotiated in an extended HELLO/HELLO_ACK. Annotations, remote control, metadata and request-to-share ride a framed TCP channel (`[type:1][len:4 BE][payload:N]`, JSON payloads).

**Every wire constant is pinned by `WireByteRegistryTests`. Add a registry row in the same commit as any new wire byte, and never renumber a shipped one.** Full protocol details: `.claude/rules/protocol.md`.

The **normative** definition — RFC 2119 MUST/SHOULD/MAY with stable requirement IDs (`TS-CTL-001`, …) — is `docs/spec.md`, and `conformance/` carries the language-neutral vectors that pin it: `make test-conformance` runs them against `sdk/go` (the public Go SDK, written from the spec and sharing no code with ours — also buildable as `libtailscreen.a` for non-Go clients), and `make test-protocol` runs the same files against the shipping Swift codecs. The stateful pipeline (reorder, depacketizers, NACK scheduling, FEC group solving, RR accounting) is pinned the other way — vectors can't express clock-driven interleavings, so `make test-differential` links the Go SDK's c-archive and drives both implementations with identical seeded input, asserting identical output at every step. A wire change touches four things in one commit: the code, the registry test, the spec's registry appendix, and a vector.

## Swift 6 conventions used here

- `@MainActor` on all UI-touching state and anywhere that constructs an `NSWindow`.
- `@unchecked Sendable` on networking classes that handle their own thread safety. We're owning the invariants, the compiler isn't checking them.
- `CVPixelBuffer` is **not** `Sendable` — convert to `CGImage` *before* hopping to `@MainActor` (e.g. for preview thumbnails).
- No `Task { … self … }` in `deinit` — do synchronous cleanup; capturing `self` after deinit starts is undefined.
- `ObservableObject` + `@Published` for UI-bound state; `@StateObject` to own, `@EnvironmentObject` to consume.
- Logging: prefer `TSLogger` from TailscaleKit. Bare `print` is fine in legacy/example code, avoid in new code.
- Errors at the UI: catch and surface via `appState.showAlertMessage(title:message:)` rather than swallowing.

## Linker / package conventions

`Package.swift` links libtailscale through a `-L` flag pointing at `Packages/TailscaleKit/lib`. Keep that path **relative** — making it absolute breaks portability and CI. Both the `Tailscreen` target and the `TailscreenTests` target carry the flag.

## Common pitfalls

- **`swift build` fails with linker errors** — you skipped `make tailscale`. The Go build emits `libtailscale.a`; without it nothing links. (And "no Package.swift" at the repo root means you forgot to `cd Apps/macOS` first.)
- **Two local instances see no peers** — both processes are sharing one Tailscale state dir. Use `./test-local.sh` (or set `TAILSCREEN_INSTANCE` manually).
- **Editing `Packages/TailscaleKit/Sources/` directly** — those paths are symlinks into the upstream submodule. Add a patch under `Packages/TailscaleKit/Patches/` instead.
- **Port 7447 lives in `NetworkConfig.tailscreenPort`** (TailscreenProtocol/NetworkConfig.swift) — the discovery, server, client, and metadata paths all read it from there. Route any new listener or dial through it rather than writing the literal.
- **Auth flow needs an active node** — interactive login only works after `Start Sharing` or `Connect to…` has initialized the tsnet node.
- **CI uses submodules.** Workflows already pass `submodules: recursive`; if you add a new workflow that builds, do the same.

Platform- and area-specific pitfalls live in the rules files below — read the matching one before working in that area.

## Where the details live

Topic detail is split into `.claude/rules/`, each scoped by `paths:` frontmatter so it loads only when working on matching files. Read one directly whenever you need it sooner:

| File | Covers | Loads for |
|------|--------|-----------|
| `.claude/rules/protocol.md` | The full 7447 wire protocol: video/audio RTP, NACK+FEC+RR loss recovery, viewer admission, annotations, remote control, metadata | TailscreenKit, both backends packages, app sources that touch the transport |
| `.claude/rules/testing.md` | Running the unit/E2E/tsnet suites, env-var affordances, `test-local.sh`, `net-impair.sh` | any `Tests/`, `scripts/`, `e2e/` |
| `.claude/rules/portable-packages.md` | TailscreenKit's six tiers, what must be `public`, which suites live where, the shared codec/HubUI/L10n packages | `Packages/TailscreenKit`, `TailscreenHubUI`, codec wrappers |
| `.claude/rules/macos-app.md` | Data-flow diagram, UI surfaces, capture-helper + picker-helper IPC, ScreenCaptureKit rules | `Apps/macOS/**` |
| `.claude/rules/localization.md` | `L(_:)`, the shared catalog, call-site conventions per UI toolkit, what not to localize | all three apps' sources, TailscreenHubUI, TailscreenL10n |
| `.claude/rules/linux.md` | GTK app, X11/portal capture, ALSA, XTEST injection + their pitfalls | `Apps/linux`, Linux backend packages |
| `.claude/rules/windows.md` | WinUI app, WGC capture, SendInput, layered-window overlay, DPI awareness | `Apps/windows`, Windows backend packages |
| `.claude/rules/tailscalekit.md` | Submodule, patch series, the Windows Go↔C bridge and runtime-start patches | `Packages/TailscaleKit/**` |
| `.claude/rules/ci.md` | Shared build definitions, the linux-packages matrix, release/soak workflows | `.github/**` |

One skill loads on demand rather than by path: **`test-catalog`** — the extracted pure-decision suites, the test-only seams, and which package a new suite belongs in. Invoke it when adding or moving a test.

Longer-form design docs (published site) live in `docs/`: `architecture.md`, `protocol.md` (with `spec.md`, the normative wire spec, as its child page), `security.md`, `platform-support.md` (the public per-platform feature matrix — update it in the same commit as any change that opens or closes a platform gap). Internal working plans — porting, the per-platform viewer plans, `platform-alignment.md` and friends — live in `plans/` at the repo root and are deliberately **not** published; keep roadmap/status prose there, not in `docs/`.

**The docs site ships with the change that makes it true.** A PR that changes anything user-facing — a feature, an install step, an artifact name, a permission prompt, a platform gap opening or closing — updates the matching page under `docs/` (`index.md`, `install.md`, `usage.md`, `platform-support.md`, `troubleshooting.md`, …) in the same PR; there is no separate docs catch-up step. This is safe to do eagerly: `docs/` on `main` publishes only to the **/next** preview channel (tailscreen.dev/next, banner + noindex), while the root site builds from the **latest release tag** (see `pages.yml`), so docs merged with a feature never promise anything unreleased — and the root flips to them automatically when the release publishes.

## Git workflow notes

- The libtailscale submodule is pinned with `ignore = dirty`, so a dirty upstream tree never shows up in `git status` — check it explicitly when a patch misbehaves.
- AI sessions develop on a designated `claude/...` branch — **do not push to `main`**. The active branch is named in the per-session prompt.
- License: MIT; upstream `libtailscale` is BSD-3-Clause.
