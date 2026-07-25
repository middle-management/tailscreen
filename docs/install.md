---
title: Install
nav_order: 2
permalink: /install/
---

# Install
{: .no_toc }

1. TOC
{:toc}

Three ways in: Homebrew, a release download, or building from source.

Most of this page is about the macOS app. There's also a **Linux desktop
app** — the GTK build, which both views and shares — with its own section
[below](#linux).

## Homebrew

```bash
brew install --cask middle-management/tap/tailscreen
```

On macOS the cask drops `Tailscreen.app` into `/Applications` — the same
signed, notarized universal binary the release page hosts. On Linux the
*same* cask links the release AppImage instead: one cask carries both
artifacts, branched on `on_macos` / `on_linux`. It lives in
[middle-management/homebrew-tap](https://github.com/middle-management/homebrew-tap)
and is bumped on each release.

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

## Linux

The Linux app is the GTK build under `Apps/linux-gtk` — one window that both
views a peer's screen and shares this machine's. It ships as an **x86_64
AppImage** attached to the same GitHub release as the Mac app:

```bash
chmod +x Tailscreen-<version>-x86_64.AppImage
./Tailscreen-<version>-x86_64.AppImage
```

Or through Homebrew, which links the same AppImage:

```bash
brew install --cask middle-management/tap/tailscreen
```

Two things to know:

- **AppImages need FUSE** to self-mount. Desktop distros generally have it;
  minimal containers often don't. If it fails with a `libfuse.so.2` error,
  install your distro's `fuse`/`libfuse2` package or run it with
  `APPIMAGE_EXTRACT_AND_RUN=1`.
- **Sharing needs X11.** Capture goes through XCB + MIT-SHM, so a Wayland
  session can view but not yet share — that needs the ScreenCast portal
  backend, which isn't written. The app detects this and says so rather than
  offering a button that always fails.

A Flatpak manifest exists under `Apps/linux-gtk/packaging/flatpak` but isn't
published yet; it needs a Swift SDK extension.

## From source

This section builds the **macOS** app; for the Linux one see
`Apps/linux-gtk` and `Apps/linux/README.md` in the repository.

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
