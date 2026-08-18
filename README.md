<p align="center">
  <img src="docs/assets/logo.svg" alt="Tailscreen logo" width="180">
</p>

# Tailscreen

[![Build Status](https://github.com/middle-management/tailscreen/actions/workflows/build.yml/badge.svg)](https://github.com/middle-management/tailscreen/actions/workflows/build.yml)

📖 **Documentation:** <https://tailscreen.dev>

Lightweight screen sharing between your machines, for the times when
spinning up a full conferencing app feels like overkill.

Tailscreen is a tiny desktop app — macOS, Linux, and Windows — that streams
one computer's screen to another over [Tailscale](https://tailscale.com/).
Every platform speaks the same wire protocol, so any of them can watch any
other, and Tailscale's WireGuard tunnel moves the bytes — directly when the
network allows, through Tailscale's encrypted relays when it doesn't. There
is no server, no port to forward, and no account to create beyond Tailscale
itself.

You choose what to share, the other person clicks your machine in their
**Screens** list, a window opens. That's the whole thing.

## What you get

- Encrypted, peer-to-peer 60 fps video, hardware-encoded where the platform
  provides it, that degrades gracefully on a bad network and snaps back.
- Automatic peer discovery — machines show up by name. No IP-typing.
- Viewer approval by default, remembered allow/deny, and per-session
  remote-control grants with an instant revoke.
- Two-way annotations, voice chat, and (from a Mac) system-audio sharing.
- Ephemeral tsnet nodes: each session's node vanishes when you stop, so
  your admin console doesn't fill up with ghosts.

## What you need

- macOS 15.2 (Sequoia) or later, Linux (x86_64 or arm64, X11 or Wayland),
  or Windows 10/11 (x64 or arm64) — in any combination on the two ends.
- A Tailscale account (the free personal tier is fine), or a
  [self-hosted control plane](https://tailscreen.dev/self-hosted/) like
  [headscale](https://github.com/juanfont/headscale).
- On a Mac: Screen Recording permission; macOS asks the first time.

## Install

Every release ships all three platforms from the same
[Releases page](https://github.com/middle-management/tailscreen/releases):

- **macOS** — `brew install --cask middle-management/tap/tailscreen`, or
  download the notarized `Tailscreen-<version>-macOS.zip` and drag to
  `/Applications`.
- **Linux** — AppImage (x86_64 / aarch64) or tarball.
- **Windows** — zip (unzip and run) or MSIX (one-time certificate trust).

Details, including the MSIX trust step and AppImage requirements:
[Install docs](https://tailscreen.dev/install/).

## Build from source

Swift Package Manager only — no Xcode project. You need a **Swift 6**
toolchain and **Go 1.21+** (build-time only, to compile `libtailscale.a`):

```bash
git clone --recurse-submodules https://github.com/middle-management/tailscreen.git
cd tailscreen
make build        # or: make run / make release / make test
```

Always go through `make` — bare `swift build` fails to link until
`make tailscale` has produced `libtailscale.a`. Forgot the submodules?
`git submodule update --init --recursive`. The Linux and Windows builds are
described in their app READMEs below, and the rest of the build story is in
the [Install](https://tailscreen.dev/install/#from-source) and
[Contributing](https://tailscreen.dev/contributing/) docs.

## The repo at a glance

- [`Apps/macOS`](Apps/macOS/README.md), [`Apps/linux`](Apps/linux/README.md),
  [`Apps/windows`](Apps/windows/README.md) — the three apps, each with its
  own README covering its platform's specifics.
- `Packages/TailscreenKit` — the portable protocol + viewer + sharer core
  they all share; the other packages are platform backends and codec
  wrappers.
- `docs/` — the published site. `docs/spec.md` is the normative wire spec,
  pinned by the conformance vectors under `conformance/`, with a public Go
  SDK in `sdk/go`.

How it fits together:
[Architecture](https://tailscreen.dev/architecture/) ·
[Network Protocol](https://tailscreen.dev/protocol/) ·
[Privacy & Security](https://tailscreen.dev/security/) ·
[Usage](https://tailscreen.dev/usage/) ·
[Troubleshooting](https://tailscreen.dev/troubleshooting/) ·
[Contributing](https://tailscreen.dev/contributing/)

## Releases

CI builds and tests every PR. Publishing a GitHub release builds, signs,
and uploads the artifacts for all three platforms, and the docs site's root
channel flips to the release tag:

```bash
git tag v1.0.0
git push origin v1.0.0
# then: GitHub UI → Releases → publish the draft
```

## License

[MIT](LICENSE). The upstream `libtailscale` is BSD-3-Clause.
