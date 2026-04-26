---
title: Contributing
nav_order: 8
permalink: /contributing/
---

# Contributing
{: .no_toc }

1. TOC
{:toc}

## Repository layout

```
tailscreen/
├── Sources/                    # Tailscreen executable (Swift, ~26 files)
├── Tests/TailscreenTests/      # Unit + connectivity tests
├── Examples/                   # Standalone API usage demo
├── TailscaleKitPackage/        # Local SwiftPM dep wrapping libtailscale
│   ├── upstream/libtailscale/  # Git submodule
│   ├── Sources/  lib/  include/   # Symlinks into upstream
│   ├── Patches/                # .patch files applied on top of upstream Swift
│   ├── Modules/libtailscale/   # Module map for the C library
│   └── libtailscale.pc         # pkg-config file (used via PKG_CONFIG_PATH)
├── e2e/docker-compose.yml      # Local headscale control plane
├── scripts/e2e-{up,down,test}.sh
├── .github/workflows/          # build.yml, release.yml, pages.yml
├── docs/                       # this site
├── Package.swift
├── Makefile                    # build entry point
└── test-local.sh               # multi-instance local launcher
```

`CLAUDE.md` at the repo root is the authoritative deep dive on every file
in `Sources/` — read it before touching anything in the video pipeline or
networking layer.

## Build & test commands

| Command            | What it does                                                    |
| :----------------- | :-------------------------------------------------------------- |
| `make build`       | Builds `libtailscale.a`, then `swift build`. Always use `make`. |
| `make run`         | Build + run the debug binary.                                   |
| `make release`     | `swift build -c release` → `.build/release/Tailscreen`.         |
| `make install`     | Release build + copy to `~/bin/Tailscreen`.                     |
| `make clean`       | Wipes `.build/`, runs `swift package clean`, cleans TailscaleKit. |
| `make test`        | Runs `swift test` (after rebuilding `libtailscale`).            |
| `make e2e-up`      | Starts a local headscale control plane in Docker.               |
| `make e2e-down`    | Tears down headscale + volume.                                  |
| `make test-e2e`    | One-shot: `e2e-up` → connectivity tests → `e2e-down`.           |

Bare `swift build` before `make tailscale` will fail at link time — you
need `libtailscale.a` first.

## TailscaleKit submodule and patches

`TailscaleKitPackage/upstream/libtailscale` is pinned in `.gitmodules` with
`ignore = dirty`. After cloning, run:

```bash
git submodule update --init --recursive
```

The patches in `TailscaleKitPackage/Patches/` are applied on top of the
upstream Swift sources during `make tailscale`. They add a `Foundation`
import, glue imports for C-bridge types, `send`/`receive` on connections,
public `logout`, listener poll-timeout handling, and the
`tsnet ListenPacket` / `PacketListener` Swift wrapper used by the UDP video
path.

**Don't edit `TailscaleKitPackage/Sources/`** — those paths are symlinks
into the submodule. Add or modify a `.patch` file instead, then re-run
`make tailscale`.

## Auth keys for tests

The connectivity tests in `Tests/TailscreenTests/TailscaleConnectivityTests.swift`
need a tsnet auth key. Two ways to provide one:

### Local headscale (preferred for CI/dev)

```bash
make test-e2e
```

Or, for a longer-running session:

```bash
eval "$(make e2e-up)"     # exports TAILSCREEN_TS_AUTHKEY + TAILSCREEN_TS_CONTROL_URL
swift test --filter TailscaleConnectivityTests
make e2e-down
```

`scripts/e2e-up.sh` brings up `e2e/docker-compose.yml` (headscale 0.26.1 on
`localhost:8080`), creates a user, and mints a reusable ephemeral pre-auth
key.

### Real tailnet

Mint an auth key in your Tailscale admin console and export it:

```bash
export TAILSCREEN_TS_AUTHKEY=tskey-...
swift test
```

## Local manual testing

Run multiple Tailscreen processes on one Mac:

```bash
./test-local.sh        # 2 instances (default)
./test-local.sh 3      # N instances
```

Each child gets `TAILSCREEN_INSTANCE=<i>`, which suffixes the Tailscale
state dir and hostname (e.g. `wisp-1`, `wisp-2`). Without it, two processes
share one Tailscale state dir and reuse the same machine key — the browser
will see zero peers because it's looking at its own node.

Memory-debug envs (set before invoking `./test-local.sh`):

| Env var                          | Effect                                                                    |
| :------------------------------- | :------------------------------------------------------------------------ |
| `TAILSCREEN_DEBUG_ZOMBIES=1`     | `NSZombieEnabled` + malloc stack logging. Over-releases log instead of crashing. |
| `TAILSCREEN_DEBUG_ASAN=1`        | Sets `ASAN_OPTIONS`. Also rebuild with `swift build -Xswiftc -sanitize=address`. |
| `TAILSCREEN_DEBUG_GMALLOC=1`     | libgmalloc — known to break ScreenCaptureKit's XPC. Prefer Instruments' Zombies template. |

Merged stdout/stderr lands in `/tmp/tailscreen-merged.log`
(`TAILSCREEN_LOG=...` to override).

## Branch policy

- AI sessions develop on a designated `claude/...` branch — **do not push to
  `main`**. The active branch is set in the per-session prompt.
- The `Build` workflow runs on push to `main` and `claude/**` and on PRs to
  `main`.

## CI

- `.github/workflows/build.yml` — `macos-latest`, Go 1.21, `make build` +
  `make test` on every PR and push.
- `.github/workflows/release.yml` — fires on a published release. Cross-
  builds a universal binary, codesigns + notarizes (when secrets are
  present), uploads `Tailscreen-<tag>-macOS.zip` + `checksums.txt`.
- `.github/workflows/pages.yml` — builds and deploys *this* docs site on
  changes under `docs/` or to the workflow itself.

## Pointers for changes

- Touching the **video pipeline** → read `RTPPacket.swift`,
  `VideoEncoder.swift`, `VideoDecoder.swift`, `MetalViewerRenderer.swift`
  together.
- Touching **annotations** → `Annotation.swift`, `ScreenShareProtocol.swift`,
  `DrawingOverlayView.swift`, `SharerOverlayWindow.swift`,
  `ViewerCommands.swift`.
- Touching **networking / discovery** → `TailscaleScreenShareServer.swift`,
  `TailscaleScreenShareClient.swift`, `TailscalePeerDiscovery.swift`,
  `TailscaleIPNWatcher.swift`, `TailscreenMetadata.swift`.
- Touching **UI / state** → `AppState.swift`, `MenuBarView.swift`,
  `AppMenu.swift`, `ViewerToolbar.swift`.
- Touching the **build** → `Makefile`, `Package.swift`,
  `TailscaleKitPackage/Makefile`, `TailscaleKitPackage/Patches/`.

## Editing the documentation site

The site is plain Jekyll. To preview locally:

```bash
cd docs
bundle install
bundle exec jekyll serve --baseurl ""
# open http://localhost:4000
```

Each page is a Markdown file under `docs/` with a `nav_order:` front-matter
key. To add a new page, create `docs/<slug>.md`, set its `nav_order`, link
to it from `docs/index.md`, and push — the `pages.yml` workflow handles the
rest.
