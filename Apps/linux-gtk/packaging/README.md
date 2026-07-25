# Packaging the Tailscreen Linux app

Installable-package recipes for the native Linux desktop app (`Apps/linux-gtk`,
the swift-cross-ui / GTK4 app whose executable product is
`tailscreen-viewer-gtk`). Three paths:

- **AppImage** — `appimage/build-appimage.sh` — built and uploaded by the
  `Release (Linux)` workflow, so this is the shipping channel today
- **Flatpak** — `flatpak/dev.tailscreen.Tailscreen.yml` (+ `.desktop` +
  `.metainfo.xml`) — the better long-term desktop channel, blocked on a Swift
  toolchain in the build sandbox (see below)
- **Homebrew** — `homebrew/` — a formula template plus an honest account of why
  Homebrew is a poor primary channel for a GTK app

All target the same app: id `dev.tailscreen.Tailscreen`, name **Tailscreen**,
command `tailscreen-viewer-gtk`.

**Only the GTK app is packaged.** `Apps/linux` also builds
`tailscreen-sharer-linux`, `tailscreen-viewer-probe` and `TailscreenTestSharer`
— development and test tools, not products — and they are deliberately absent
from every artifact here.

The executable is still named `tailscreen-viewer-gtk` for continuity, though
the app both views *and* shares since it gained a sharing card. Renaming the
product is a follow-up that would touch the CI job names, the packaging
recipes, and anyone's muscle memory, so it hasn't been done casually.

## Honest status

Neither recipe is verified to build in this repository's CI. Packaging a Swift +
GTK4 + tsnet app needs a full desktop toolchain (GTK4 dev libs, GPU/GL, FFmpeg,
ALSA, Opus), a **Swift 6 toolchain**, **Go** (to compile `libtailscale.a`), and a
**live network** (SwiftPM resolves swift-cross-ui; the first libtailscale build
downloads Go modules) — none of which the CI container for the viewer's build
job provides beyond a headless render self-test. The manifests and script are
written to be **structurally correct and self-documenting** so they can be run on
a real workstation; treat them as a starting point, not a turnkey pipeline.

What is verified: the app itself builds and passes its headless GL render
self-test in the `linux-gtk-viewer` CI job (see `.github/workflows/build.yml`).
The packaging wrappers here drive that same `swift build` and then bundle the
resulting binary — the wrapping/bundling steps are what remain unverified.

Packaging deliberately **does not gate merges** — it can't run in the normal CI
container. `.github/workflows/release-linux.yml` runs it instead on three
triggers: a published release (the real thing), `workflow_dispatch` against an
existing tag, and a pull request labelled **`build-linux-package`**, which
builds the AppImage and attaches it to the run as an artifact without uploading
to any release. The label exists so packaging breakage is discoverable before a
tag rather than at one.

## Prerequisites (both paths)

The viewer's own build dependencies (see the `linux-gtk-viewer` CI job):

```
libgtk-4-dev gir1.2-gtk-4.0 libgirepository1.0-dev libepoxy-dev libglib2.0-dev \
libgl1-mesa-dri libopus-dev pkg-config golang-go make gcc libc6-dev \
libavcodec-dev libavutil-dev libasound2-dev
```

plus a Swift 6 toolchain (swift.org).

## Flatpak

`flatpak/dev.tailscreen.Tailscreen.yml` builds from the repo source against the
GNOME runtime (`org.gnome.Platform//47` / `org.gnome.Sdk//47`), which supplies
GTK4. It compiles `libtailscale.a` (Go, via the `org.freedesktop.Sdk.Extension.golang`
SDK extension) and then `swift build -c release --product tailscreen-viewer-gtk`.

**The one gap: Swift.** The GNOME SDK does not ship a Swift toolchain, and there
is no official Swift SDK extension. Two ways to close it:

1. **Supply Swift in the build sandbox** — unpack a swift.org Linux toolchain
   into the build (e.g. add it as an extra `archive` source that installs under
   `/usr/lib/sdk/swift` and prepend it to `append-path`), or base the manifest on
   a community Swift SDK extension if one is available for your runtime version.
2. **Bundle a host-prebuilt binary** — build `tailscreen-viewer-gtk` on the host
   (`swift build -c release`), then change the module to `buildsystem: simple`
   with a single `type: file` source for the binary and `install` it, dropping
   the `swift build` / `make` steps. Simpler, but the binary must match the
   runtime's glibc/GTK ABI.

Run (from the repo root, once Swift is available to the SDK):

```bash
flatpak install flathub org.gnome.Platform//47 org.gnome.Sdk//47 \
  org.freedesktop.Sdk.Extension.golang//24.08
flatpak-builder --user --install --force-clean build-flatpak \
  Apps/linux-gtk/packaging/flatpak/dev.tailscreen.Tailscreen.yml
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
Apps/linux-gtk/packaging/appimage/build-appimage.sh
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
  `Apps/linux-gtk/packaging/icons/dev.tailscreen.Tailscreen.png` **if present** and
  skips it otherwise.

To finish this properly, add a real
`Apps/linux-gtk/packaging/icons/dev.tailscreen.Tailscreen.png` (256×256, ideally plus
128/64 sizes) generated from `docs/assets/app-icon.svg`, e.g.:

```bash
rsvg-convert -w 256 -h 256 docs/assets/app-icon.svg \
  -o Apps/linux-gtk/packaging/icons/dev.tailscreen.Tailscreen.png
```
