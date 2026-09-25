# CLAUDE.md

Guidance for AI agents in this repo. If you change the build, layout, or protocol, update this file (or the matching `.claude/rules/` file) in the same commit. Keep these files terse: rules, pitfalls with their symptom and fix, and non-obvious "why" — not history or anything `rg` can find.

## Project

**Tailscreen**: low-latency encrypted P2P screen sharing over Tailscale. Native apps for **macOS 15.2+** (`Apps/macOS`, the reference implementation), **Linux** (`Apps/linux`, GTK4) and **Windows** (`Apps/windows`, WinUI) speak one wire protocol and interoperate fully. System-audio capture is macOS-only. **Share via Link** (share-by-token) admits guests without a Tailscale account over a per-link ephemeral WireGuard tunnel, behind mandatory per-join approval; a macOS share can run link-only with no sign-in. SwiftPM only — no Xcode project.

macOS UI: a docked main window (sign-in, accounts, peer list — the hub) plus a `MenuBarExtra` sharer tool. While sharing, the whole sharing view renders on **both** surfaces from the same components.

## Tech stack

- **Swift 6**, strict concurrency. macOS target **15.2** (needed for `SCContentFilter.includedDisplays`/`includedWindows`/`includedApplications` getters used by the picker-helper).
- **Go** at build time for `libtailscale.a`. `GOTOOLCHAIN=auto` fetches the version the submodule's `go.mod` pins — except Debian/Ubuntu apt Go, which disables that (CI uses `actions/setup-go`).
- **libopus** at build time (`brew install opus` / `apt install libopus-dev`), via `Packages/OpusKit`'s `COpus` systemLibrary.
- ScreenCaptureKit, VideoToolbox (H.264/HEVC), Metal (`CAMetalLayer`); tsnet ephemeral nodes.

Runtime: Screen Recording permission, and interactive Tailscale login or `TAILSCREEN_TS_AUTHKEY` (+ optional `TAILSCREEN_TS_CONTROL_URL`). Link join and macOS link-only sharing need neither.

## Layout

- `Apps/{macOS,linux,windows}` — one SwiftPM package each (linux/windows use swift-cross-ui).
- `Packages/TailscreenKit` — portable (Linux-buildable) protocol + viewer + sharer core used by all three apps.
- `Packages/TailscaleKit` — wraps libtailscale, a submodule of [our fork](https://github.com/middle-management/libtailscale) (branch `tailscreen-main`).
- `Packages/TailscreenHubUI` — shared hub UI for the swift-cross-ui apps. `Packages/TailscreenL10n` — the one string catalog (`L(_:)`) all apps read.
- Other `Packages/*` are platform backends (X11/portal/XTEST/ALSA… on Linux; WGC/SendInput/WASAPI… on Windows) or codec wrappers.
- `sdk/go` — public Go SDK of the wire protocol, written from `docs/spec.md` and sharing no code with ours; also built as `libtailscreen.a`. `conformance/` — language-neutral vectors. `web/viewer` — browser viewer (Go → js/wasm).
- `docs/` — published site. `plans/` — internal plans, not published; roadmap/status prose goes there.

## Build & test

**Always go through `make`** — it sets `PKG_CONFIG_PATH` so SwiftPM finds `libtailscale.pc` (and `sdk/go/libtailscreen.pc`). After a fresh clone: `git submodule update --init --recursive`. First build needs network.

Non-obvious targets (each reproduces the CI job of the same name):
- `make test-protocol` — portable TailscreenKit, no Apple frameworks; runs on Linux (`linux-protocol`). Builds `libtailscale.a` first (a link-time input for `TailscreenSharerTests`).
- `make test-differential` — Swift pipeline vs Go SDK driven with identical seeded input (`Packages/TailscreenDifferential`). Separate package because two Go c-archives can't share one binary.
- `make test-conformance` — vectors against `sdk/go`. CI's `linux-conformance` also runs `cd sdk/go && go test ./...` and `make libtailscreen-check`; reproduce all three before calling it flaky.
- `make test-l10n` — catalog tests, plain and under TSan; scans all app source trees for missing `L("…")` keys (the only check on GTK/WinUI strings).
- `make merge-diagnostics FILES="a.jsonl b.jsonl"` — merge two diagnostics bundles; needs no libtailscale/Go/libopus.
- `make test-e2e` — local headscale in Docker. `make web-viewer` / `make test-web-spike` — see `.claude/rules/web-viewer.md`.

Bare `swift` commands for the mac app run from `Apps/macOS/` (no manifest at the root), and only after `make tailscale`.

## Protocol

Port **7447** TCP+UDP (`NetworkConfig.tailscreenPort` — never write the literal). RTP over UDP: video PT 96 H.264 / 97 HEVC, audio PT 98 voice / 99 system. Loss recovery FEC → NACK → PLI, negotiated in HELLO/HELLO_ACK. Control channel over TCP: `[type:1][len:4 BE][payload:N]`, JSON payloads. The same protocol runs unchanged inside the guest tunnel; guests are a second admission class (identity = node key, deny evicts at the tunnel). Details: `.claude/rules/protocol.md`.

- **Every wire constant is pinned by `WireByteRegistryTests`; never renumber a shipped one.** A wire change touches four things in one commit: code, registry test, `docs/spec.md` registry appendix, and a conformance vector.
- `docs/spec.md` is normative (RFC 2119, requirement IDs like `TS-CTL-001`).
- **Session diagnostics** are a local JSONL event stream, not on the wire. On by default in release candidates, off in stable. Event names are a never-rename registry (`DiagnosticEventNameTests`). See `.claude/rules/diagnostics.md`.

## Swift conventions

- `@MainActor` on UI state and anything constructing an `NSWindow`. `@unchecked Sendable` on networking classes that own their thread safety.
- **Never `Synchronization.Mutex`** — TSan can't see it, so `linux-tsan` passing says nothing. Use `Guarded` (TailscreenProtocol) for new lock-guarded state, or a plain `NSLock`. Multi-threaded types need a test that touches them from several threads.
- `CVPixelBuffer` isn't `Sendable` — convert to `CGImage` before hopping to `@MainActor`.
- No `Task { … self … }` in `deinit`.
- Log with `TSLogger`, not `print`. Surface UI errors via `appState.showAlertMessage(title:message:)`.
- The `-L` to `Packages/TailscaleKit/lib` in `Package.swift` must stay **relative**.

## Pitfalls

- **Linker errors on `swift build`** → run `make tailscale` first.
- **Two local instances see no peers** → shared state dir; use `./test-local.sh` or `TAILSCREEN_INSTANCE`.
- **`Packages/TailscaleKit/Sources/` are symlinks into the submodule** → commit + push in the submodule on `tailscreen-main`, then bump the pointer, or the edit is lost.
- **Interactive login needs a running node** (after Start Sharing / Connect to…).
- **New workflows that build need `submodules: recursive`.**

## Where details live

`.claude/rules/*.md` load automatically by `paths:` frontmatter; read one directly if needed sooner: `protocol`, `testing`, `portable-packages`, `macos-app`, `localization`, `linux`, `windows`, `tailscalekit`, `ci`, `web-viewer`, `diagnostics`. The **`test-catalog`** skill covers where a new test goes and the test seams — invoke it when adding or moving a test.

**User-facing changes update `docs/` in the same PR** (`index.md`, `install.md`, `usage.md`, `platform-support.md`, `troubleshooting.md`, …). Safe to do eagerly: `main`'s docs publish only to tailscreen.dev/next; the root site builds from the latest release tag. `docs/platform-support.md` changes with any platform gap opening or closing.

## Git

- Develop on the designated `claude/...` branch; **never push to `main`**.
- AI remote sessions: plain `curl` to `api.github.com` is authenticated by the proxy for the scoped repos (artifacts download via `/actions/artifacts/<id>/zip`, run/job queries, re-runs). Pushing tags and creating Releases are refused — hand the human a prepared `releases/new?tag=…&prerelease=1&body=…` link.
- License MIT; upstream libtailscale BSD-3-Clause.
