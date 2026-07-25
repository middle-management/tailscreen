# X11CaptureKit

X11 screen capture for the Linux sharer, producing the tightly-packed I420
planes a video encoder consumes.

Wrapped the way `ALSAKit` wraps libasound and `FFmpegKit` wraps libavcodec:

| Target          | What it is                                                        |
|-----------------|-------------------------------------------------------------------|
| `CXCB`          | `systemLibrary` over libxcb + the MIT-SHM extension                |
| `CX11Capture`   | C shim — XCB/shared-memory boilerplate + the BGRA→I420 conversion  |
| `X11CaptureKit` | Foundation-only Swift wrapper (`X11ScreenCapture`)                 |

The C shim exists for the same reason `CGtkVideo` does on the viewer side:
keep Swift out of a C API's boilerplate, and keep a per-pixel loop somewhere a
compiler will vectorise it.

## Why X11 before the ScreenCast portal

`org.freedesktop.portal.ScreenCast` (PipeWire) is the right production path,
especially on Wayland, and it stays on the roadmap. But it needs a session bus,
a running compositor, and a user consent dialog — so it **can never run in
CI**. X11 capture runs headlessly under Xvfb, which is what makes the
`linux-x11-capture` job possible.

Both sit behind the portable `CaptureEncoding` seam
(`Packages/TailscreenKit/Sources/TailscreenSharer/SharerBackends.swift`), so
adding the portal backend later changes no caller.

## Scope

Root-window capture of one X display. Deliberately **not** covered:

- **Per-window / per-application capture.** Needs the compositor's
  cooperation; that's the portal's job. The `CaptureEncoding` backend built on
  this (`TailscreenSharerLinux.X11CaptureEncoder`) *refuses* such a selection
  rather than falling back to the whole screen — sharing more than the user
  picked is a privacy failure, not a degraded feature.
- **Wayland.** No X11 root window to grab. (XWayland exposes one, but it
  contains only XWayland clients, not the desktop.)
- **Cursor compositing.** MIT-SHM `GetImage` doesn't include the pointer.

## Colour: limited-range BT.709

The conversion emits **limited-range BT.709** — luma 16–235, chroma 128±112 —
because that is exactly what the viewer's YUV→RGB fragment shader
(`Apps/linux-gtk/Sources/CGtkVideo/cgtkvideo.c`) assumes.

This is worth stating loudly: getting the range or matrix wrong doesn't fail,
it just makes every frame washed out or crushed, which is easy to ship and
annoying to diagnose. `CaptureTests` pins it by transcribing the shader's math
and asserting the primaries survive the round trip, so the two can't drift
apart silently.

## Build & test

```bash
# Debian/Ubuntu
sudo apt-get install -y pkg-config libxcb1-dev libxcb-shm0-dev xvfb

swift test --package-path Packages/X11CaptureKit                    # conversion only
xvfb-run -a --server-args="-screen 0 1280x720x24" \
  swift test --package-path Packages/X11CaptureKit                  # + live capture
```

Without a `$DISPLAY` the capture tests self-skip and the conversion tests still
run. CI's `linux-x11-capture` job runs the Xvfb form.

## Performance note

`x11cap_uses_shm` reports whether the zero-copy MIT-SHM path is active. When it
isn't — a remote display, mainly — every frame costs a full-screen transfer
over the X socket, which at 1080p60 is roughly 500 MB/s. Pixels are identical
either way, so this is a throughput question, not a correctness one, but it's
worth logging on a share that feels slow.
