# tailscreen (Linux)

The native Linux desktop app — a full **sharer and viewer**, the sibling of
`Apps/macOS` and `Apps/windows`. Package name `tailscreen-linux`; the
executable is plain `tailscreen`, the same name the Windows app ships.

UI is [swift-cross-ui](https://github.com/stackotter/swift-cross-ui) on its GTK4
backend. Video is a downstream `GtkVideoView` — a swift-cross-ui `View` hosting
a `GtkGLArea` with an OpenGL BT.709 YUV→RGB renderer — because a declarative
toolkit has no primitive for "hand me a texture 60 times a second". The hub
chrome (header, screen rows, login/share cards, session placard) comes from
`Packages/TailscreenHubUI`, shared verbatim with the Windows app.

## What it does

Everything the protocol supports, minus what needs a Mac:

| | |
|---|---|
| **View** a shared screen | libavcodec decode → GL render, ALSA audio |
| **Share** your screen | X11 capture (libxcb + MIT-SHM) → libavcodec encode |
| Remote control | both directions — send as a viewer, receive as a sharer |
| Annotations | both directions |
| Multiple accounts | tsnet state dirs under `$XDG_CONFIG_HOME/tailscreen` |

**Sharing needs X11.** The gate is `$DISPLAY`: with it unset (headless, or a
Wayland session without XWayland) the share button is disabled and says why,
rather than offering something that always fails.

Under a Wayland compositor *with* XWayland, `$DISPLAY` is set, so sharing is
offered — but `X11CaptureKit` sees only the XWayland root window, so native
Wayland windows won't appear in what viewers get. The ScreenCast portal is the
real answer and isn't written yet. Viewing is unaffected either way.

## Running it

```
tailscreen [<sharer-host>] [--port N] [--state-dir PATH] [--control-url URL]
tailscreen --render-self-test
tailscreen --overlay-self-test
```

With a host argument the viewer dials it directly. **Without** one it enters
picker mode: brings the tsnet node up, discovers Tailscreen peers on the
tailnet, and shows the screen list to choose from.

| env var | effect |
|---|---|
| `TAILSCREEN_TS_AUTHKEY` | pre-auth key; skips interactive login |
| `TAILSCREEN_TS_CONTROL_URL` | non-default control plane (e.g. local headscale) |

`--render-self-test` is the headless CI gate: it renders a colour-bars frame,
reads the pixels back through GL, and exits. No network, no tsnet — it exists so
a broken renderer fails a PR instead of a user's first launch.

`--overlay-self-test` is its sharer-side twin, for the annotation overlay: it
draws a red stroke on the overlay and reads the screen back through the sharer's
*own* X11 capture, asserting the chroma at the stroke against a control point
elsewhere. It needs a **compositing** X server (see below) — and that is not a
test-harness quirk, it is the feature: on an uncomposited session the overlay
deliberately refuses to exist, because an ARGB window with no compositor has no
alpha and would paint a black rectangle over your screen. When that happens the
app withholds `ScreenShareCaps.annotations`, so viewers see a disabled drawing
toolbar rather than strokes that reach nobody.

## Building it

```bash
sudo apt-get install -y \
  libgtk-4-dev gir1.2-gtk-4.0 libgirepository1.0-dev libepoxy-dev \
  libgl1-mesa-dri libavcodec-dev libavutil-dev libasound2-dev \
  libopus-dev pkg-config golang-go make gcc libc6-dev

make tailscale                                    # builds libtailscale.a (needs Go)
swift build --package-path Apps/linux --product tailscreen
```

`make tailscale` first, always: the app pulls `TailscreenViewerTsnet`, which
links the Go c-archive. Without it the build compiles and then fails at link.
Run `swift build` from the **repo root** with `--package-path` (which is what CI
does) so `PKG_CONFIG_PATH` resolves `libtailscale.pc` — the root `Makefile` sets
it for you.

Xvfb is additionally needed to run `--render-self-test` headlessly:

```bash
xvfb-run -a --server-args="-screen 0 1280x720x24" \
  swift run --package-path Apps/linux tailscreen --render-self-test
```

`--overlay-self-test` needs Xvfb *plus* a compositor, and the compositor has to
be running before the app opens the display — `gdk_display_is_composited` is read
once, when the overlay is created, so one that starts afterwards is one the app
never sees. `xvfb-run` can't sequence that, hence the explicit server:

```bash
sudo apt-get install -y xvfb xcompmgr
Xvfb :95 -screen 0 1280x720x24 & sleep 2
DISPLAY=:95 xcompmgr & sleep 1
DISPLAY=:95 swift run --package-path Apps/linux tailscreen --overlay-self-test
```

## What it depends on

```
Apps/linux                        this package
├── Packages/TailscreenLinuxBackends   FFmpeg decode, ALSA out, X11 capture+encode
├── Packages/TailscreenKit             protocol, ViewerSession, the sharer server,
│                                      and the shared tsnet transport
├── Packages/TailscreenHubUI           the hub's look, shared with Windows
└── Packages/TailscaleKit              libtailscale.a
```

The split from `TailscreenLinuxBackends` is deliberate: that package carries no
UI toolchain, so the `linux-viewer` CI job builds and tests the decode → audio
pipeline without paying for GTK4 or swift-cross-ui.

swift-cross-ui is pinned to an **exact revision**, not a range. Its `View`
protocol is young and reshapes across versions, and our coupling to it
(`GtkVideoView`) is small enough that a surprise upgrade costs more than it
gains.

## Packaging

`packaging/` holds the distribution manifests — see
[`packaging/README.md`](packaging/README.md).

- **AppImage** (`packaging/appimage/build-appimage.sh`) — x86_64 and aarch64,
  built by `release-linux`. The primary download; needs FUSE to self-mount.
- **Tarball** — the no-FUSE fallback, same contents, both arches.
- **Flatpak** (`packaging/flatpak/`) — a manifest exists but nothing is
  published to Flathub yet.
- **Homebrew** (`packaging/homebrew/`) — the cask links the release AppImage.

## CI

| job | what it proves |
|---|---|
| `linux-app` | builds this package, runs the Xvfb render self-test **and the annotation-overlay self-test** (second Xvfb, with `xcompmgr`), and typechecks the **Windows** app on the same runner |
| `linux-app-arm64` | the same on `ubuntu-24.04-arm`, release config — a hard gate, not compile-only |
| `linux-viewer` | the backends package's real decode + capture tests |

A **live** tsnet run is local-only: GitHub's runners can't complete the
userspace-WireGuard handshake, so anything that calls `node.up()` is run by hand
against a local headscale (`scripts/e2e-up-native.sh`). See
`scripts/e2e-linux-sharer.sh` for the scripted Linux sharer → Linux viewer
end-to-end.
