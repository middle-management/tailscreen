# Packaging the Tailscreen Linux app

Installable-package recipes for the native Linux desktop app (`Apps/linux`,
the swift-cross-ui / GTK4 app whose executable product is
`tailscreen`). Three paths:

- **AppImage** — `appimage/build-appimage.sh` — built and uploaded by the
  `Release (Linux)` workflow, so this is the shipping channel today
- **Flatpak** — `flatpak/dev.tailscreen.Tailscreen.yml` (+ `.desktop` +
  `.metainfo.xml`) — the better long-term desktop channel, blocked on a Swift
  toolchain in the build sandbox (see below)
- **Homebrew** — `homebrew/` — no recipe of its own: the Linux AppImage is
  carried by the *same* cask as the macOS app in
  `middle-management/homebrew-tap`, branched `on_macos` / `on_linux`. The
  README there explains that shape and why Homebrew is still a poor primary
  channel for a GTK app

All target the same app: id `dev.tailscreen.Tailscreen`, name **Tailscreen**,
command `tailscreen`.

**Only the GTK app is packaged.** `Packages/TailscreenLinuxBackends` also builds
`tailscreen-sharer-linux`, `tailscreen-viewer-probe` and `TailscreenTestSharer`
— development and test tools, not products — and they are deliberately absent
from every artifact here.

The executable is plain `tailscreen` — the app is a full sharer *and* viewer,
same as the macOS and Windows apps. Config (profiles + node state) lives in
`$XDG_CONFIG_HOME/tailscreen`, falling back to `~/.config/tailscreen`.

## Honest status

**AppImage: verified.** `release-linux.yml` built one end to end on a GitHub
runner — Go c-archive, Swift 6 toolchain, GTK4 deps, `linuxdeploy` + its GTK
plugin, `appimagetool` — producing a ~99 MB `Tailscreen-<version>-x86_64.AppImage`
in about 11 minutes. What that proves is that the artifact *builds and bundles*;
nobody has yet run the resulting AppImage on a desktop, so "it launches and
shares a screen" remains unverified.

**Flatpak: unverified.** The manifest still needs a Swift toolchain inside the
build sandbox (see below) and has never been built. It's written to be
structurally correct and self-documenting — a starting point, not a turnkey
pipeline.

Separately, the app itself builds and passes its headless GL render self-test in
the `linux-app` CI job (see `.github/workflows/build.yml`), which is the
same `swift build` the packaging wrappers drive.

Packaging deliberately **does not gate merges** — it can't run in the normal CI
container. `.github/workflows/release-linux.yml` runs it instead on three
triggers: a published release (the real thing), `workflow_dispatch` against an
existing tag, and a pull request labelled **`build-linux-package`**, which
builds the AppImage and attaches it to the run as an artifact without uploading
to any release. The label exists so packaging breakage is discoverable before a
tag rather than at one.

## Prerequisites (both paths)

The viewer's own build dependencies (see the `linux-app` CI job):

```
libgtk-4-dev gir1.2-gtk-4.0 libgirepository1.0-dev libepoxy-dev libglib2.0-dev \
libgl1-mesa-dri libopus-dev pkg-config golang-go make gcc libc6-dev \
libavcodec-dev libavutil-dev libasound2-dev libdbus-1-dev libpipewire-0.3-dev
```

plus a Swift 6 toolchain (swift.org).

**libdbus and libpipewire are RUNTIME dependencies too**, not only build ones.
The app links `PortalCaptureKit` so it can capture a Wayland session at all —
X11 root capture cannot, and on Wayland `$DISPLAY` is XWayland's, which is why
the app refuses that path rather than silently sharing a near-empty screen. The
AppImage picks both up from the binary's `DT_NEEDED` via linuxdeploy, but the
**tarball does not bundle them**: a machine running the tarball needs
`libdbus-1-3` and `libpipewire-0.3-0` present, which every desktop that has a
portal already does. Distro packaging should depend on them explicitly.

## Flatpak

`flatpak/dev.tailscreen.Tailscreen.yml` builds from the repo source against the
GNOME runtime (`org.gnome.Platform//47` / `org.gnome.Sdk//47`), which supplies
GTK4. It compiles `libtailscale.a` (Go, via the `org.freedesktop.Sdk.Extension.golang`
SDK extension) and then `swift build -c release --product tailscreen`.

**The one gap: Swift.** The GNOME SDK does not ship a Swift toolchain, and there
is no official Swift SDK extension. Two ways to close it:

1. **Supply Swift in the build sandbox** — unpack a swift.org Linux toolchain
   into the build (e.g. add it as an extra `archive` source that installs under
   `/usr/lib/sdk/swift` and prepend it to `append-path`), or base the manifest on
   a community Swift SDK extension if one is available for your runtime version.
2. **Bundle a host-prebuilt binary** — build `tailscreen` on the host
   (`swift build -c release`), then change the module to `buildsystem: simple`
   with a single `type: file` source for the binary and `install` it, dropping
   the `swift build` / `make` steps. Simpler, but the binary must match the
   runtime's glibc/GTK ABI.

Run (from the repo root, once Swift is available to the SDK):

```bash
flatpak install flathub org.gnome.Platform//47 org.gnome.Sdk//47 \
  org.freedesktop.Sdk.Extension.golang//24.08
flatpak-builder --user --install --force-clean build-flatpak \
  Apps/linux/packaging/flatpak/dev.tailscreen.Tailscreen.yml
flatpak run dev.tailscreen.Tailscreen            # picker mode
flatpak run dev.tailscreen.Tailscreen my-sharer  # dial a host directly
```

`finish-args` grants: Wayland + fallback-X11 + `dri` (the GTK4/OpenGL video
surface), PulseAudio (audio playback), and `network` (the tsnet transport dials
the tailnet). Validate the metadata with
`appstreamcli validate flatpak/dev.tailscreen.Tailscreen.metainfo.xml`.

## AppImage

`appimage/build-appimage.sh` builds the release binary, assembles an `AppDir`
(binary + generated `.desktop` + icon + `AppRun`), and runs
[`linuxdeploy`](https://github.com/linuxdeploy/linuxdeploy) (with the
`linuxdeploy-plugin-gtk` plugin, if installed, to pull in GTK's runtime data) to
bundle shared libraries and emit the AppImage via
[`appimagetool`](https://github.com/AppImage/appimagetool). Those two tools are
**not** bundled — install them yourself (see the script header).

```bash
Apps/linux/packaging/appimage/build-appimage.sh
# → Tailscreen-x86_64.AppImage in the repo root
# Override the output path: OUTPUT=/tmp/tv.AppImage Apps/.../build-appimage.sh
```

The script self-checks for `swift`, `go`, `make`, `cc`, `pkg-config`, and
`linuxdeploy` and fails early with the missing tool named.

## Icon (follow-up)

Both recipes reference an app icon but **no raster icon ships yet** — this is a
documented follow-up:

- The macOS app's icon lives at `Apps/macOS/Resources/Tailscreen.icns`, and the
  source artwork is `docs/assets/app-icon.svg` (the same SVG the top-level
  `make icon` target renders the `.icns` from).
- The **AppImage** script renders a 256×256 PNG from `docs/assets/app-icon.svg`
  at build time if `rsvg-convert` (librsvg) is installed; otherwise it writes a
  1×1 placeholder so the build still completes.
- The **Flatpak** manifest installs
  `Apps/linux/packaging/icons/dev.tailscreen.Tailscreen.png` **if present** and
  skips it otherwise.

To finish this properly, add a real
`Apps/linux/packaging/icons/dev.tailscreen.Tailscreen.png` (256×256, ideally plus
128/64 sizes) generated from `docs/assets/app-icon.svg`, e.g.:

```bash
rsvg-convert -w 256 -h 256 docs/assets/app-icon.svg \
  -o Apps/linux/packaging/icons/dev.tailscreen.Tailscreen.png
```
