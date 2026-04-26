---
title: Contributing
nav_order: 8
permalink: /contributing/
---

# Contributing
{: .no_toc }

1. TOC
{:toc}

The codebase is small enough that you can hold most of it in your head
after a couple of hours. This page is a tour through the layout, the
build, and the rough edges that are worth knowing about up front.

`CLAUDE.md` at the repo root is the deeper version of this page,
file-by-file. Read it before touching the video pipeline or the
networking layer.

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
│   └── libtailscale.pc         # pkg-config file (consumed via PKG_CONFIG_PATH)
├── e2e/docker-compose.yml      # Local headscale control plane
├── scripts/e2e-{up,down,test}.sh
├── .github/workflows/          # build.yml, release.yml, pages.yml
├── docs/                       # this site
├── Package.swift
├── Makefile                    # build entry point — always go through this
└── test-local.sh               # multi-instance local launcher
```

## Build commands

| Command            | What it does                                                       |
| :----------------- | :----------------------------------------------------------------- |
| `make build`       | Build `libtailscale.a`, then `swift build`. Always start here.    |
| `make run`         | Build + run the debug binary.                                      |
| `make release`     | `swift build -c release` → `.build/release/Tailscreen`.            |
| `make install`     | Release build + copy to `~/bin/Tailscreen`.                        |
| `make clean`       | Wipe `.build/`, run `swift package clean`, clean TailscaleKit.     |
| `make test`        | `swift test` (after rebuilding `libtailscale`).                    |
| `make e2e-up`      | Start a local headscale control plane in Docker.                   |
| `make e2e-down`    | Tear down headscale + volume.                                      |
| `make test-e2e`    | One-shot: `e2e-up` → connectivity tests → `e2e-down`.              |

A reminder we're going to repeat in every section because it's the most
common build failure: **bare `swift build` will fail to link** until
`make tailscale` (or `make build`) has produced `libtailscale.a`.
Always start with `make`.

## TailscaleKit and the patches

`TailscaleKitPackage/upstream/libtailscale` is a submodule pinned in
`.gitmodules` with `ignore = dirty`. After cloning, run:

```bash
git submodule update --init --recursive
```

The patches under `TailscaleKitPackage/Patches/` get applied on top of the
upstream Swift sources during `make tailscale`. There are 16 of them at
last count, all small. They add things like:

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

`Tests/TailscreenTests/TailscaleConnectivityTests.swift` spins up two
ephemeral tsnet nodes in-process and tests the full transport. It needs
an auth key.

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

`scripts/e2e-up.sh` brings up `e2e/docker-compose.yml` (headscale 0.26.1
on `localhost:8080`), creates a user, and mints a reusable ephemeral
pre-auth key.

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
`main`**. The active branch is named in the per-session prompt.

The `Build` workflow runs on push to `main`, on push to `claude/**`, and
on PRs to `main`.

## CI

Three workflows under `.github/workflows/`:

- **`build.yml`** — `macos-latest`, Go 1.21, runs `make build` + `make test`
  on every PR and push.
- **`release.yml`** — fires when a GitHub release is **published**. Cross-
  builds a universal Mach-O, codesigns + notarizes (when secrets are
  present), uploads `Tailscreen-<tag>-macOS.zip` + `checksums.txt`. The
  signing/notarization secrets are: `APPLE_DEVELOPER_ID_CERT_P12`,
  `APPLE_DEVELOPER_ID_CERT_PASSWORD`, `APPLE_NOTARY_API_KEY_P8`,
  `APPLE_NOTARY_API_KEY_ID`, `APPLE_NOTARY_API_ISSUER_ID`. Without all
  five, the workflow uploads an unsigned `.app` and prints a warning.
- **`pages.yml`** — builds and deploys *this* docs site when anything
  under `docs/` changes.

## Where to start reading

Map of common changes to the files you'll touch:

- **Video pipeline** — `RTPPacket.swift`, `VideoEncoder.swift`,
  `VideoDecoder.swift`, `MetalViewerRenderer.swift`. Read them together;
  they form one logical unit.
- **Annotations** — `Annotation.swift`, `ScreenShareProtocol.swift`,
  `DrawingOverlayView.swift`, `SharerOverlayWindow.swift`,
  `ViewerCommands.swift`.
- **Networking and discovery** — `TailscaleScreenShareServer.swift`,
  `TailscaleScreenShareClient.swift`, `TailscalePeerDiscovery.swift`,
  `TailscaleIPNWatcher.swift`, `TailscreenMetadata.swift`.
- **UI and state** — `AppState.swift`, `MenuBarView.swift`,
  `AppMenu.swift`, `ViewerToolbar.swift`.
- **Build** — `Makefile`, `Package.swift`,
  `TailscaleKitPackage/Makefile`, `TailscaleKitPackage/Patches/`.

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
`pages.yml` workflow handles the rest.
