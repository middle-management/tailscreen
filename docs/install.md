---
title: Install
nav_order: 2
permalink: /install/
---

# Install
{: .no_toc }

1. TOC
{:toc}

There are two ways in: grab a release, or build from source. Both end up
with `Tailscreen.app`.

## From a release

Go to the [Releases page](https://github.com/middle-management/tailscreen/releases),
download `Tailscreen-<version>-macOS.zip`, unzip, drag to `/Applications`.
Done.

The release zip is a universal binary (`arm64` + `x86_64`), built and
notarized by `release.yml` on a `macos-15` runner. If the build secrets
aren't configured (forks, dry runs), you'll get an unsigned `.app` instead
— Gatekeeper will yell at you the first time you open it.

## From source

The project is Swift Package Manager only. There is no Xcode project and
there is no plan for one. Builds go through the top-level
[`Makefile`](https://github.com/middle-management/tailscreen/blob/main/Makefile)
because that's where `PKG_CONFIG_PATH` gets set so SwiftPM can find the C
library it needs to link against.

### What you need installed

- macOS 15.0 (Sequoia) or later.
- Swift 6.0 toolchain. Xcode 16+ ships it; alternatively
  [swift.org](https://swift.org/download/) has standalone installers.
- **Go 1.21 or newer.** This is a build-time dependency, not a runtime one.
  The Go compiler turns Tailscale's source into `libtailscale.a`, which the
  Swift code then links against. Once you've built, you can uninstall Go and
  the app keeps working.

### Clone — with submodules

Tailscale's C library lives in a submodule under
`TailscaleKitPackage/upstream/libtailscale`. If you forget the recursive
clone, the build will fail with a confusing missing-headers error. So:

```bash
git clone --recurse-submodules https://github.com/middle-management/tailscreen.git
```

Or, if you've already done a regular clone:

```bash
git submodule update --init --recursive
```

### Build

```bash
make build
```

This compiles `libtailscale.a` from the Go submodule, applies the patches
under `TailscaleKitPackage/Patches/` to the upstream Swift sources (more on
that in [Contributing]({% link contributing.md %})), builds the TailscaleKit
wrapper, and finally builds the app. First build pulls Go modules, so it
needs internet.

### Run

```bash
make run
```

Or build once and run the binary directly:

```bash
.build/debug/Tailscreen
```

### Release build and install

```bash
make release           # → .build/release/Tailscreen
make install           # release + copy to ~/bin/Tailscreen
```

## Don't skip `make`

The single most common build failure is running bare `swift build` first.
That will fail to link, because `libtailscale.a` doesn't exist yet — the Go
toolchain hasn't been invoked. Always do `make build` (or at least
`make tailscale`) once. After that, `swift build` works fine for the rest of
the build tree.

## Permissions

The first time you hit "Start Sharing", macOS will pop up a Screen Recording
prompt. Approve it in **System Settings → Privacy & Security → Screen
Recording**, then quit Tailscreen and relaunch. macOS will not pick up the
new permission until the process restarts. This is macOS's rule, not ours.

## Uninstall

Quit Tailscreen, drag `Tailscreen.app` to the trash. If you want to nuke the
ephemeral-node state too:

```bash
rm -rf ~/Library/Application\ Support/Tailscreen
```

That's it. There's no installer, no daemon, no LaunchAgent.
