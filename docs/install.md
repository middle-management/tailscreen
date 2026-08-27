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

The Linux app is the GTK build under `Apps/linux` — one window that both
views a peer's screen and shares this machine's. It ships in two flavors,
attached to the same GitHub release as the Mac app:

- **AppImage** — self-contained, no install step, for both architectures
  (`Tailscreen-<version>-x86_64.AppImage` /
  `Tailscreen-<version>-aarch64.AppImage`):

  ```bash
  chmod +x Tailscreen-<version>-x86_64.AppImage
  ./Tailscreen-<version>-x86_64.AppImage
  ```

- **tarball** (`Tailscreen-<version>-linux-<arch>.tar.gz`) — the same app as
  a plain tarball, for machines without FUSE. Unpack it and run `tailscreen`
  from inside the folder. It carries the Swift runtime beside the binary
  (no distro packages that), but it does **not** carry GTK4, FFmpeg, ALSA or
  the GL drivers — install those from your distro, and see the bundled
  `README.txt` for the package names.

**Which distros the AppImage runs on.** It bundles its libraries but *not*
glibc — glibc has to match your kernel's loader, so it can never be bundled.
The build therefore sets a floor:

| Your distro | glibc | AppImage |
| :--- | :--- | :---: |
| Ubuntu 22.04 LTS and newer | 2.35+ | ✅ |
| Debian 12 bookworm and newer | 2.36+ | ✅ |
| Fedora 36 and newer | 2.35+ | ✅ |
| RHEL / Rocky / Alma 9 | 2.34 | ❌ |
| Anything older | < 2.35 | ❌ |

If it fails with `version 'GLIBC_2.xx' not found`, your distro is below the
floor — there is no workaround short of building from source, because the
error comes from the dynamic loader before any of our code runs.

Two more things to know:

- **AppImages need FUSE** to self-mount. Desktop distros generally have it;
  minimal containers often don't. If it fails with a `libfuse.so.2` error,
  install your distro's `fuse`/`libfuse2` package or run it with
  `APPIMAGE_EXTRACT_AND_RUN=1`.
- **Wayland shares through the desktop portal.** An X11 session captures
  directly; a Wayland session shares via the ScreenCast portal, so expect
  your compositor's consent dialog when the share starts. A Wayland session
  with no portal (headless or minimal setups) refuses to share and says
  why, rather than capturing the empty XWayland root.

A Flatpak manifest exists under `Apps/linux/packaging/flatpak` but isn't
published yet; it needs a Swift SDK extension.

## Windows

The Windows app views **and** shares — sign in, watch a peer, or share your
own screen with remote control and annotations. Each release carries native
**x64** and **arm64** builds, and two ways in:

- **Zip**: download `Tailscreen-<version>-windows-x64.zip` (or `-arm64`),
  unzip anywhere, run `tailscreen.exe`. Everything it needs — the Swift
  runtime, the Windows App SDK, FFmpeg — is in the folder; no installer, no
  admin rights, nothing else to install.
- **MSIX**: a per-arch installer package
  (`Tailscreen-<version>-windows-<arch>.msix`) for a proper Start-menu
  install with clean uninstall. It's currently signed with Tailscreen's own
  certificate rather than one Windows already trusts, so installing takes a
  one-time extra step — trusting that certificate — described next.

Pick the arch that matches your machine — an arm64 laptop runs the arm64
build natively, and Windows will refuse a mismatched MSIX outright.

### Installing the MSIX (trusting the certificate)

Each release ships the public half of its signing certificate beside the
MSIX (`Tailscreen-<version>-windows-<arch>.cer`). Trust it once and the
MSIX installs like any other package — and since releases sign with the
same certificate, future upgrades install without repeating this step.

From an **administrator** PowerShell in your download folder:

```powershell
Import-Certificate -FilePath .\Tailscreen-<version>-windows-x64.cer `
  -CertStoreLocation Cert:\LocalMachine\TrustedPeople
Add-AppxPackage .\Tailscreen-<version>-windows-x64.msix
```

Or without a terminal: double-click the `.cer` → **Install Certificate…** →
**Local Machine** → **Place all certificates in the following store** →
Browse → **Trusted People** → Finish. Then double-click the `.msix` and
click Install.

### Pre-release MSIX packages install alongside, not over

A release candidate's MSIX deliberately carries a different package
identity (`Tailscreen.TailscreenRC`) from a release's
(`Tailscreen.Tailscreen`) — MSIX has no notion of a pre-release, and a
shared identity could make Windows refuse the real release on a machine
that had tried the candidate. So an RC installs *beside* any Tailscreen
you already have, and doesn't upgrade into the release: uninstall the RC
when the real version ships. Running both at once isn't supported — two
copies contend for the same port.

What you're agreeing to, spelled out: the certificate goes into the
machine's **Trusted People** store — not a root authority — which tells
Windows to accept packages signed with exactly that certificate and
nothing broader. Verify the download against
`checksums-windows-<arch>.txt` from the release page first, and you can
remove the trust at any time (`certlm.msc` → Trusted People → delete the
Tailscreen entry). This whole step disappears once releases are signed
with a certificate that chains to a trusted root (SignPath's free
open-source code signing — in progress), which is also what unlocks
`winget install`.

## From source

This section builds the **macOS** app. For Linux, see `Apps/linux` and
`Packages/TailscreenLinuxBackends/README.md` in the repository; for
Windows, the build is CI-defined — the shared
`.github/workflows/app-windows.yml` is the authoritative recipe (Swift 6.3
+ llvm-mingw for the Go archive), and every CI run uploads a runnable app
artifact.

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

This compiles `libtailscale.a` from the Go submodule — our fork of
libtailscale, which carries the Swift-glue and guest-tunnel changes as
ordinary commits (more on that in
[Contributing]({{ site.baseurl }}{% link contributing.md %}#tailscalekit-and-the-fork)) —
builds the TailscaleKit wrapper, and finally builds the app. First build
pulls Go modules, so it needs internet.

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
standing prompt: on X11 capture permission is implicit in the session, on
Wayland the compositor's portal dialog asks per share, and on Windows the
system picker is the consent step.

## Uninstall

- **macOS:** quit Tailscreen, drag `Tailscreen.app` to the trash. State
  lives in `~/Library/Application Support/Tailscreen` if you want to nuke
  the ephemeral-node state too.
- **Linux:** delete the AppImage or tarball directory; state lives in
  `~/.config/tailscreen`.
- **Windows:** delete the unzipped folder (or uninstall the MSIX from
  Settings → Apps).

That's it. There's no daemon, no LaunchAgent, no background service.
