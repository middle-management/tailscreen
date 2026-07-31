---
title: Install
nav_order: 2
permalink: /install/
---

# Install
{: .no_toc }

1. TOC
{:toc}

Tailscreen runs on **macOS**, **Linux**, and **Windows** — every release
ships all three from the same
[Releases page](https://github.com/middle-management/tailscreen/releases).
Pick your platform: [macOS](#homebrew) (Homebrew or a release download),
[Linux](#linux) (AppImage or tarball), [Windows](#windows) (zip or MSIX) —
or [build from source](#from-source).

## Homebrew

```bash
brew install --cask middle-management/tap/tailscreen
```

The cask drops `Tailscreen.app` into `/Applications` — the same signed,
notarized universal binary the release page hosts. It lives in
[middle-management/homebrew-tap](https://github.com/middle-management/homebrew-tap)
and is bumped on each release. (Homebrew casks are macOS-only; on Linux,
grab the AppImage from the [Linux](#linux) section instead.)

To upgrade later:

```bash
brew upgrade --cask tailscreen
```

To remove:

```bash
brew uninstall --cask tailscreen
```

## From a release (macOS)

Go to the [Releases page](https://github.com/middle-management/tailscreen/releases),
download `Tailscreen-<version>-macOS.zip`, unzip, drag to `/Applications`.
Done.

The release zip is a universal binary (`arm64` + `x86_64`), built,
codesigned and notarized by CI. If the build secrets aren't configured
(forks, dry runs), you'll get an unsigned `.app` instead — Gatekeeper will
yell at you the first time you open it.

## Linux

The Linux app is the GTK build under `Apps/linux-gtk` — one window that both
views a peer's screen and shares this machine's. It ships in two flavors,
attached to the same GitHub release as the Mac app:

- **x86_64 AppImage** — self-contained, no install step:

  ```bash
  chmod +x Tailscreen-<version>-x86_64.AppImage
  ./Tailscreen-<version>-x86_64.AppImage
  ```

- **arm64 tarball** (`Tailscreen-<version>-linux-arm64.tar.gz`) — the same
  app as a plain tarball (the AppImage tooling doesn't ship arm64 builds
  yet). Unpack it and run the bundled `tailscreen` binary; it needs the
  distro's GTK4 and GL libraries installed.

The executable is plain `tailscreen`. If you used an earlier release, your
sign-in carries over — the app migrates the old
`~/.config/tailscreen-viewer-gtk` state directory to `~/.config/tailscreen`
automatically on first launch.

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

## Windows

The Windows app views **and** shares — sign in, watch a peer, or share your
own screen with remote control and annotations. Each release carries native
**x64** and **arm64** builds:

- **Zip** (recommended today): download
  `Tailscreen-<version>-windows-x64.zip` (or `-arm64`), unzip anywhere, run
  `tailscreen.exe`. Everything it needs — the Swift runtime, the Windows App
  SDK, FFmpeg — is in the folder; there's no installer and nothing else to
  install.
- **MSIX**: a per-arch installer package also sits on the release, but it's
  currently **self-signed** — Windows won't install it until you trust the
  signing certificate, which is more hassle than the zip. A trust-chained
  signature (and with it a `winget install` path) is in progress; until
  then, use the zip.

Pick the arch that matches your machine — an arm64 laptop runs the arm64
build natively, and Windows will refuse a mismatched MSIX outright.

## From source

This section builds the **macOS** app. For Linux, see `Apps/linux-gtk` and
`Apps/linux/README.md` in the repository; for Windows, the build is
CI-defined — `.github/workflows/windows-build.yml` is the authoritative
recipe (Swift 6.3 + llvm-mingw for the Go archive), and every CI run uploads
a runnable app artifact.

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

On macOS, the first time you share, a Screen Recording
prompt pops up. Approve it in **System Settings → Privacy & Security → Screen
Recording**, then quit and relaunch — macOS only applies the new
permission to a restarted process. Linux and Windows have no equivalent
prompt: capture permission is implicit in the session (X11) or granted
through the system picker (Windows).

## Uninstall

- **macOS:** quit Tailscreen, drag `Tailscreen.app` to the trash. State
  lives in `~/Library/Application Support/Tailscreen` if you want to nuke
  the ephemeral-node state too.
- **Linux:** delete the AppImage or tarball directory; state lives in
  `~/.config/tailscreen`.
- **Windows:** delete the unzipped folder (or uninstall the MSIX from
  Settings → Apps).

That's it. There's no daemon, no LaunchAgent, no background service.
