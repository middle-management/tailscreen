---
title: Contributing
nav_order: 10
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
├── Apps/
│   ├── macOS/                  # The macOS app — a SwiftPM package (run app
│   │                           #   `swift` commands from this directory)
│   ├── linux/                  # The Linux app — swift-cross-ui / GTK4
│   └── windows/                # The Windows app — swift-cross-ui / WinUI
├── Packages/                   # Local SwiftPM packages the apps depend on
│   ├── TailscreenKit/          # Portable protocol + viewer + sharer core all
│   │                           #   three apps share (builds and tests on Linux)
│   ├── TailscreenHubUI/        # Shared hub chrome for the GTK + WinUI apps
│   ├── TailscaleKit/           # Wraps libtailscale
│   │   ├── upstream/libtailscale/  # Git submodule — our fork's tailscreen-main branch
│   │   └── libtailscale.pc     # pkg-config file (consumed via PKG_CONFIG_PATH)
│   └── …                       # Platform backends (X11CaptureKit,
│                               #   PortalCaptureKit, XTestInjectKit,
│                               #   WGCCaptureKit, SendInputKit, WASAPIKit,
│                               #   ALSAKit, …) and codec wrappers (OpusKit,
│                               #   FFmpegKit, TailscreenVideoFFmpeg)
├── e2e/docker-compose.yml      # Local headscale control plane
├── scripts/e2e-{up,down,test}.sh
├── .github/workflows/
├── docs/                       # this site
├── plans/                      # working design plans (not published)
├── Makefile                    # build entry point — always go through this
└── test-local.sh               # multi-instance local launcher
```

The Makefile drives the macOS app; the Linux and Windows apps are their own
SwiftPM packages built with `swift build --package-path Apps/linux` /
`Apps/windows` (system dependencies and the authoritative CI recipes are
listed in [Install → From source]({{ site.baseurl }}{% link install.md %}#from-source)).

## Build commands

`make` with no arguments prints a one-line description of every
target (`.DEFAULT_GOAL := help`). The highlights:

| Command             | What it does                                                       |
| :------------------ | :----------------------------------------------------------------- |
| `make build`        | Build `libtailscale.a`, then `swift build`. Always start here.    |
| `make run`          | Build + run the debug binary.                                      |
| `make release`      | `swift build -c release` → `Apps/macOS/.build/release/Tailscreen`.            |
| `make install`      | Release build + copy to `~/bin/Tailscreen`.                        |
| `make clean`        | Wipe `.build/`, run `swift package clean`, clean TailscaleKit.     |
| `make test`         | `swift test` (after rebuilding `libtailscale`).                    |
| `make test-protocol`| Test the portable TailscreenKit package — no Apple frameworks, no built `libtailscale.a`; also runs on Linux. |
| `make test-l10n`    | Test the shared string catalog; its suites scan all four source trees for `L("…")` keys the catalog is missing. |
| `make test-tsan`    | `swift test` under ThreadSanitizer — catches data races strict concurrency can't. ~3x slower, so not part of `make test`. |
| `make lint`         | Run SwiftLint (baseline-gated; only new violations fail).          |
| `make format`       | Run `swift-format` in-place over the app + TailscreenKit sources.          |
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

## TailscaleKit and the fork

`Packages/TailscreenKit`'s transport wraps `libtailscale` via the
`Packages/TailscaleKit/upstream/libtailscale` submodule, which points at
**our fork** — `middle-management/libtailscale`, branch `tailscreen-main`:
upstream `tailscale/libtailscale` history with our changes as ordinary
commits on top. After cloning, run:

```bash
git submodule update --init --recursive
```

The commits used to be a `.patch` series applied at build time; they were
converted one-to-one into fork commits, so there is no patch step anymore
— `make tailscale` just builds what the submodule pins. They're all
focused: Swift-facing glue (`send`/`receive` on connections, a public
`logout`, listener poll-timeout handling), the `tsnet ListenPacket` /
`PacketListener` wrapper for the UDP video path, Linux and Windows
portability, and the guest (share-by-token) surface — the per-link
tunnel node behind Share via Link.

**Editing `Packages/TailscaleKit/Sources/` edits the submodule** — those
paths are symlinks into it. That's fine, but the change must be committed
*in the submodule* on `tailscreen-main`, pushed to the fork, and the
submodule pointer bumped here; an uncommitted submodule edit is invisible
to everyone else. Keep each change one logical commit so it can become an
upstream PR later.

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
cd Apps/macOS && swift test --filter TailscaleConnectivityTests
make e2e-down
```

`scripts/e2e-up.sh` brings up `e2e/docker-compose.yml` (headscale on
`localhost:8080`), creates a user, and mints a reusable ephemeral pre-auth
key.

### Real tailnet

Mint an auth key in the Tailscale admin console, export it, run tests:

```bash
export TAILSCREEN_TS_AUTHKEY=tskey-...
cd Apps/macOS && swift test
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
[Troubleshooting → Two local instances see no peers]({{ site.baseurl }}{% link troubleshooting.md %}#two-local-instances-see-no-peers).

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
