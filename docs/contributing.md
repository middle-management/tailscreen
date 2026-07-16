---
title: Contributing
nav_order: 9
permalink: /contributing/
---

# Contributing
{: .no_toc }

1. TOC
{:toc}

The codebase is small enough to hold most of it in your head after a
couple of hours. This page tours the layout, the build, and the rough
edges worth knowing up front.

`CLAUDE.md` at the repo root has the same orientation in a denser form,
aimed at AI assistants working in the tree.

## Repository layout

```
tailscreen/
├── Sources/                    # Tailscreen executable (Swift)
├── Tests/TailscreenTests/      # Unit + connectivity tests
├── Examples/                   # Standalone API usage demo
├── TailscaleKitPackage/        # Local SwiftPM dep wrapping libtailscale
│   ├── upstream/libtailscale/  # Git submodule
│   ├── Sources/  lib/  include/   # Symlinks into upstream
│   ├── Patches/                # .patch files applied on top of upstream Swift
│   ├── Modules/libtailscale/   # Module map for the C library
│   └── libtailscale.pc         # pkg-config file (consumed via PKG_CONFIG_PATH)
├── e2e/docker-compose.yml      # Local headscale control plane
├── scripts/e2e-{up,down,test}.sh
├── .github/workflows/
├── docs/                       # this site
├── Package.swift
├── Makefile                    # build entry point — always go through this
└── test-local.sh               # multi-instance local launcher
```

## Build commands

`make` with no arguments prints a one-line description of every
target (`.DEFAULT_GOAL := help`). The highlights:

| Command             | What it does                                                       |
| :------------------ | :----------------------------------------------------------------- |
| `make build`        | Build `libtailscale.a`, then `swift build`. Always start here.    |
| `make run`          | Build + run the debug binary.                                      |
| `make release`      | `swift build -c release` → `.build/release/Tailscreen`.            |
| `make install`      | Release build + copy to `~/bin/Tailscreen`.                        |
| `make clean`        | Wipe `.build/`, run `swift package clean`, clean TailscaleKit.     |
| `make test`         | `swift test` (after rebuilding `libtailscale`).                    |
| `make lint`         | Run SwiftLint (baseline-gated; only new violations fail).          |
| `make format`       | Run `swift-format` in-place over `Sources/` and `Tests/`.          |
| `make format-check` | Run `swift-format` in lint mode (no changes). CI uses this.        |
| `make e2e-up`       | Start a local headscale control plane in Docker.                   |
| `make e2e-down`     | Tear down headscale + volume.                                      |
| `make test-e2e`     | One-shot: `e2e-up` → connectivity tests → `e2e-down`.              |

`swift-format` ships with the Swift toolchain on Xcode 16+; if it isn't
on your `PATH`, `brew install swift-format` works as a fallback. The
config lives at `.swift-format` in the repo root.

The most common build failure, worth repeating: **bare `swift build`
fails to link** until `make tailscale` (or `make build`) has produced
`libtailscale.a`. Always start with `make`.

## TailscaleKit and the patches

`TailscaleKitPackage/upstream/libtailscale` is a submodule pinned in
`.gitmodules` with `ignore = dirty`. After cloning, run:

```bash
git submodule update --init --recursive
```

The patches under `TailscaleKitPackage/Patches/` get applied on top of the
upstream Swift sources during `make tailscale`. They're all small. They
add things like:

- A `Foundation` import the upstream forgets in some files.
- Glue imports for the C-bridge types.
- `send`/`receive` on connections.
- A public `logout`.
- Listener poll-timeout handling.
- The `tsnet ListenPacket` / `PacketListener` Swift wrapper for the UDP
  video path.

**Don't edit `TailscaleKitPackage/Sources/` directly.** Those paths are
symlinks into the submodule. You'll lose your edits the next `make
tailscale` run, plus the changes won't survive a fresh clone. Add or
modify a `.patch` file instead and re-run `make tailscale`.

## Auth keys for connectivity tests

The connectivity tests spin up two ephemeral tsnet nodes in-process and
test the full transport. They need an auth key.

### Local headscale (preferred for CI and dev)

```bash
make test-e2e
```

That runs the whole `e2e-up` → tests → `e2e-down` cycle in one shot. For
a longer session:

```bash
eval "$(make e2e-up)"     # exports TAILSCREEN_TS_AUTHKEY + TAILSCREEN_TS_CONTROL_URL
swift test --filter TailscaleConnectivityTests
make e2e-down
```

`scripts/e2e-up.sh` brings up `e2e/docker-compose.yml` (headscale on
`localhost:8080`), creates a user, and mints a reusable ephemeral pre-auth
key.

### Real tailnet

Mint an auth key in the Tailscale admin console, export it, run tests:

```bash
export TAILSCREEN_TS_AUTHKEY=tskey-...
swift test
```

Without an auth key, the connectivity tests will skip or fail — that's
expected.

## Local manual testing

Multiple Tailscreen processes on one Mac:

```bash
./test-local.sh        # 2 instances
./test-local.sh 3      # N instances
```

Each child gets `TAILSCREEN_INSTANCE=<i>`, which suffixes the Tailscale
state directory and hostname (`wisp-1`, `wisp-2`, ...). If you launch the
binary directly without setting this, all instances share one state
directory, all of them present the same machine key, and the tailnet
considers them the same device — see
[Troubleshooting → Two local instances see no peers]({% link troubleshooting.md %}#two-local-instances-see-no-peers).

Memory-debug envs (set them before invoking `./test-local.sh`):

| Env var                          | Effect                                                                   |
| :------------------------------- | :----------------------------------------------------------------------- |
| `TAILSCREEN_DEBUG_ZOMBIES=1`     | `NSZombieEnabled` + malloc stack logging. Over-releases log instead of crashing. |
| `TAILSCREEN_DEBUG_ASAN=1`        | Sets `ASAN_OPTIONS`. **Also rebuild with** `swift build -Xswiftc -sanitize=address`. |
| `TAILSCREEN_DEBUG_GMALLOC=1`     | libgmalloc — known to break ScreenCaptureKit's XPC. Prefer Instruments' Zombies template instead. |

Merged stdout/stderr lands in `/tmp/tailscreen-merged.log` (override with
`TAILSCREEN_LOG`). Ctrl-C kills the whole process group.

## Branch policy

AI sessions develop on a `claude/...` branch — **don't push directly to
`main`**. The active branch is named in the per-session prompt. CI runs
on PRs.

## CI

CI builds and runs tests on every PR. A published GitHub release triggers
a universal-binary build, which codesigns and notarizes when the Apple
secrets are configured and uploads the zipped `.app` plus a checksums file
to the release. Without all of those secrets the workflow logs a warning
and uploads an unsigned build (useful for forks). A separate workflow
deploys this docs site when anything under `docs/` changes.

## Where to start reading

The areas worth reading end-to-end: the video pipeline (capture → encode
→ RTP → decode → render), the capture-helper subprocess boundary (the
helper owns `SCStream` and the encoder; the main process only spawns it
and broadcasts what comes back), and the Tailscale integration (peer
discovery, IPN bus, auth). Audio/voice and annotations are smaller,
self-contained subsystems. Use `rg` to find specific files.

## Editing the docs site

The site is plain Jekyll using the `just-the-docs` remote theme. Local
preview:

```bash
cd docs
bundle install
bundle exec jekyll serve --baseurl ""
# open http://localhost:4000
```

Each page is a Markdown file under `docs/` with a `nav_order:` front-
matter key. To add a new page: drop a Markdown file in `docs/`, set its
`nav_order` and `permalink`, link to it from `docs/index.md`, push. The
deploy workflow handles the rest.
