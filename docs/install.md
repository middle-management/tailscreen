---
title: Install
nav_order: 2
permalink: /install/
---

# Install
{: .no_toc }

1. TOC
{:toc}

Three ways in: Homebrew, a release download, or building from source. All
end up with `Tailscreen.app`.

## Homebrew

```bash
brew install middle-management/tap/tailscreen
```

The cask drops `Tailscreen.app` into `/Applications` — the same signed,
notarized universal binary the release page hosts. The formula lives in
[middle-management/homebrew-tap](https://github.com/middle-management/homebrew-tap)
and is bumped automatically on each release.

To upgrade later:

```bash
brew upgrade --cask tailscreen
```

To remove:

```bash
brew uninstall --cask tailscreen
```

## From a release

Go to the [Releases page](https://github.com/middle-management/tailscreen/releases),
download `Tailscreen-<version>-macOS.zip`, unzip, drag to `/Applications`.
Done.

The release zip is a universal binary (`arm64` + `x86_64`), built,
codesigned and notarized by CI. If the build secrets aren't configured
(forks, dry runs), you'll get an unsigned `.app` instead — Gatekeeper will
yell at you the first time you open it.

## From source

The project is Swift Package Manager only — no Xcode project, none
planned. Builds go through the top-level
[`Makefile`](https://github.com/middle-management/tailscreen/blob/main/Makefile),
which sets `PKG_CONFIG_PATH` so SwiftPM can find the C library it links
against.

### What you need installed

- macOS 15.0 (Sequoia) or later.
- Swift 6.0 toolchain. Xcode 16+ ships it; alternatively
  [swift.org](https://swift.org/download/) has standalone installers.
- **Go 1.21 or newer.** Build-time only: Go compiles Tailscale's source
  into `libtailscale.a` for the Swift code to link against. Uninstall it
  afterwards and the app keeps working.

### Clone — with submodules

Tailscale's C library lives in a submodule under
`Packages/TailscaleKit/upstream/libtailscale`. Forget the recursive clone
and the build fails with a confusing missing-headers error. So:

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
under `Packages/TailscaleKit/Patches/` to the upstream Swift sources (more on
that in [Contributing]({% link contributing.md %})), builds the TailscaleKit
wrapper, and finally builds the app. First build pulls Go modules, so it
needs internet.

### Run

```bash
make run
```

Or build once and run the binary directly:

```bash
Apps/macOS/.build/debug/Tailscreen
```

### Release build and install

```bash
make release           # → Apps/macOS/.build/release/Tailscreen
make install           # release + copy to ~/bin/Tailscreen
```

## Always start with `make`

The most common first-time failure is bare `swift build`: it fails to link
because `libtailscale.a` doesn't exist yet. Run `make build` (or at least
`make tailscale`) once; after that, `swift build` works fine.

## Permissions

The first time you share, macOS pops a Screen Recording
prompt. Approve it in **System Settings → Privacy & Security → Screen
Recording**, then quit and relaunch — macOS only applies the new
permission to a restarted process.

## Uninstall

Quit Tailscreen, drag `Tailscreen.app` to the trash. If you want to nuke the
ephemeral-node state too:

```bash
rm -rf ~/Library/Application\ Support/Tailscreen
```

That's it. There's no installer, no daemon, no LaunchAgent.
