# tailscreen-viewer (Linux/Windows viewer)

The portable screen-share **viewer** executable — the host that plugs concrete
platform backends into the portable `ViewerSession` data-plane core
(`Packages/TailscreenKit`'s `TailscreenViewer` target). Where the macOS app
decodes with VideoToolbox, renders with Metal, and plays audio through
AVAudioEngine, this viewer uses:

| Role      | Backend                          | Seam it satisfies |
|-----------|----------------------------------|-------------------|
| Decode    | `FFmpegKit` (libavcodec)         | `VideoDecoding`   |
| Render    | `SDLKit` (SDL2 YUV window)       | `VideoSink`       |
| Audio     | `ALSAKit` (libasound)            | `AudioSink`       |
| Transport | `TailscaleKit` (tsnet UDP)       | `receiveRTP` / `onControlToSend` / `tick` |

All the receive-side *logic* (RTP demux, reassembly, NACK/PLI feedback,
receiver reports, audio decode) lives in the portable, unit-tested
`ViewerSession`. The code here is deliberately thin: three adapters bridging
the backends to the protocol seams, plus a tsnet transport that pumps datagrams
in and ships control bytes out.

## Layout

```
Apps/linux/
├── Package.swift
├── Sources/
│   ├── TailscreenViewerCore/     # library — CI-testable, NO tsnet
│   │   ├── Adapters.swift        #   FFmpeg/SDL/ALSA → VideoDecoding/VideoSink/AudioSink
│   │   └── ViewerPipeline.swift  #   assembles a ViewerSession + sinks
│   └── TailscreenViewerCLI/      # executable `tailscreen-viewer`
│       ├── TsnetTransport.swift  #   tsnet UDP connect + run loop (local-only live)
│       └── main.swift            #   arg parsing + real-backend wiring
└── Tests/TailscreenViewerCoreTests/
    └── PipelineIntegrationTests.swift  # real H.264 → RTP → decode → sink
```

The package is split so the decode→render→audio pipeline is provable in CI
without the tsnet/Go dependency: `TailscreenViewerCore` depends only on the A/V
backends and the portable core. The `tailscreen-viewer` executable adds the
`TailscaleKit` dependency (and thus the built `libtailscale.a`).

## Build & test

Needs a Swift 6 toolchain and system dev libraries:

```bash
# Debian/Ubuntu
sudo apt-get install -y \
  libavcodec-dev libavutil-dev libsdl2-dev libasound2-dev libopus-dev \
  pkg-config golang-go make gcc libc6-dev \
  libxml2 libcurl4-openssl-dev libedit2 libpython3-dev libz3-dev  # Swift runtime deps

# libtailscale.a (the executable links it; the Core library + test don't)
make -C ../../Packages/TailscaleKit

# Build everything + run the pipeline integration test
PKG_CONFIG_PATH="$PWD/../../Packages/TailscaleKit" swift test --package-path .
```

`swift test` builds and links the whole package (including the executable), so
it needs `libtailscale.a` present — which also makes it the Linux link-check
for the tsnet binary. The `linux-viewer` CI job runs exactly this.

## Run (local-only)

A live session needs a real tailnet (or a local headscale) — the same
constraint as every tsnet path in this repo, so it can't run in CI.

```bash
export TAILSCREEN_TS_AUTHKEY=tskey-…          # or TAILSCREEN_TS_CONTROL_URL for headscale
.build/debug/tailscreen-viewer <sharer-host> [--port 7447] [--no-audio] \
    [--state-dir PATH] [--control-url URL]
```

The window opens at 1280×720 and resizes to the sharer's first decoded frame.
Close the window to end the session.

### Authentication

- **With `TAILSCREEN_TS_AUTHKEY`** (a reusable ephemeral key from the Tailscale
  admin console): the node joins headlessly — no prompt. Best for repeated runs
  and headless boxes.
- **Without a key:** the viewer falls back to **interactive browser login**. It
  subscribes to the tsnet IPN bus before bringing the node up, catches the
  `BrowseToURL` login link, prints it prominently on stderr, and (only if a
  desktop `DISPLAY` is present) best-effort `xdg-open`s it. Open that URL in a
  browser to approve; the node then comes up. The node is **ephemeral**, so a
  fresh run generally re-prompts — a reusable key avoids that.

## Running under OrbStack (macOS host)

The handiest way to exercise the live path from a Mac: run the **sharer**
(`Tailscreen.app`) on the Mac and the **viewer** in an OrbStack Linux machine.
The viewer brings up its *own* ephemeral tsnet node inside the guest, so the
Linux side needs **no** host Tailscale and nothing shared from the Mac — just
outbound network (OrbStack provides it) and a way onto the same tailnet: a
reusable auth key (simplest for a guest), or the interactive browser login the
viewer falls back to when no key is set (see [Authentication](#authentication)).

### 1. Create a machine and build

An OrbStack **machine** (not a plain container) auto-mounts your Mac home, so
your checkout is visible at the same path.

```bash
orb create ubuntu:noble tsviewer
orb -m tsviewer                       # shell into the guest

sudo apt update
sudo apt install -y clang git make gcc libc6-dev pkg-config \
  libavcodec-dev libavutil-dev libsdl2-dev libasound2-dev libopus-dev golang-go \
  libxml2 libcurl4-openssl-dev libedit2 libpython3-dev libz3-dev   # Swift runtime deps
# Swift 6.1 via swiftly:
curl -sL https://swiftlang.github.io/swiftly/swiftly-install.sh | bash
. ~/.local/share/swiftly/env.sh && swiftly install 6.1 && swiftly use 6.1

cd ~/…/tailscreen                     # same path as on the Mac
git submodule update --init --recursive
make -C Packages/TailscaleKit         # libtailscale.a (Go)
cd Apps/linux
PKG_CONFIG_PATH="$PWD/../../Packages/TailscaleKit" swift build
```

> **Shared-mount gotcha:** OrbStack bind-mounts your Mac home, so the checkout
> is shared. `Packages/TailscaleKit/upstream/libtailscale/libtailscale.a` is
> the one build artifact that's OS-specific *and* lives at a fixed path — if
> the Mac built it first, `make -C Packages/TailscaleKit` says *"Nothing to be
> done"* and you'll later hit `undefined reference to tailscale_*` at link
> time (a Mach-O archive can't link on Linux). Force a Linux rebuild:
> ```bash
> rm -f Packages/TailscaleKit/upstream/libtailscale/libtailscale.{a,h}
> GOFLAGS=-buildvcs=false make -C Packages/TailscaleKit
> ```
> This overwrites the Mac's copy, so run `make tailscale` on the Mac again when
> you switch back (it's the only file that ping-pongs). To avoid it entirely,
> clone into a path **outside** the mount (e.g. `/opt/build/tailscreen`) — that
> tree keeps its own Linux `libtailscale.a` and also builds faster on native
> disk.

### 2. Smoke test first — headless (no display needed)

Confirm the tsnet connect + decode path works before dealing with a display.
SDL's dummy driver still uploads frames; you just watch the logs:

```bash
export TAILSCREEN_TS_AUTHKEY=tskey-auth-...        # same tailnet as the Mac
SDL_VIDEODRIVER=dummy .build/debug/tailscreen-viewer <sharer-host> --no-audio
```

`<sharer-host>` is the Mac sharer's **Tailscale node hostname** (from the
Tailscale admin console, or the mac app's log — the ephemeral node it
registers). Expect `[tsnet] … up` → `HELLO sent` → the receive loop running.

### 3. Show the actual window (GUI over X11)

The SDL renderer needs an X11 display. OrbStack forwards X11 from a Linux
machine to an X server on the Mac — you supply the X server (XQuartz):

1. **Install + start XQuartz on the Mac** (one-time):
   ```bash
   brew install --cask xquartz
   ```
   Then **log out and back in** (XQuartz needs a fresh login the first time),
   and launch XQuartz.
2. **Allow network clients:** XQuartz → *Settings… → Security* → tick
   *“Allow connections from network clients.”* Quit and relaunch XQuartz so it
   takes effect.
3. **Check the display is wired up in the guest.** OrbStack usually sets
   `DISPLAY` for you:
   ```bash
   echo "$DISPLAY"                    # e.g. ":0" or "host.docker.internal:0"
   ```
   If it's **empty**, set it and authorize the guest from the Mac:
   ```bash
   # on the Mac (Terminal):
   xhost + 127.0.0.1
   # in the guest:
   export DISPLAY=host.docker.internal:0
   ```
4. **Sanity-check the display path** independent of Tailscreen — a plain X11
   app should pop a window on your Mac:
   ```bash
   sudo apt install -y x11-apps && xeyes
   ```
   If `xeyes` doesn't show, fix the display before touching the viewer (it's an
   XQuartz/`DISPLAY` issue, not a Tailscreen one). Note `xeyes` uses **no**
   OpenGL, so it succeeding only proves plain X11 works — XQuartz's GLX is
   separately broken (it can't hand Mesa a usable FBConfig), which is why the
   viewer renders through SDL's **software** renderer by default rather than the
   accelerated `opengl` one (whose GLX context creation would fatally X-error).
5. **Run for real** — same command as the smoke test, minus the dummy driver
   (and drop `--no-audio` only if the guest has a working ALSA device; usually
   it doesn't, so leave it):
   ```bash
   export TAILSCREEN_TS_AUTHKEY=tskey-auth-...
   .build/debug/tailscreen-viewer <sharer-host> --no-audio
   ```
   The window opens on your Mac and resizes to the sharer's first frame.

### Notes

- **Audio:** an OrbStack guest normally has no ALSA device — keep `--no-audio`
  (a missing device is treated as non-fatal, so audio is optional either way).
- **GPU-accelerated rendering:** off by default (see the GLX note above). On a
  native Linux desktop with working OpenGL, set `TAILSCREEN_SDL_ACCELERATED=1`
  to use SDL's `opengl` renderer for GPU scaling. Leave it unset for forwarded
  X11 / XQuartz, where accelerated rendering fatally X-errors.
- **Local headscale instead of a real tailnet:** point *both* sides at it — on
  the Mac `eval "$(make e2e-up)"`, and pass the viewer
  `--control-url http://<mac-lan-ip>:8080` with the same key. More moving parts
  (the guest must reach the host's `:8080` and DERP), so prefer a real tailnet
  unless you specifically want to avoid one.

## Not here yet

- **FEC ingest** — `ViewerSession` degrades to NACK-or-PLI until the deferred
  `FECGroupBuffer` work lands (tracked in `ViewerSession.swift`'s `TODO(fec)`).
- **Remote control / annotations send** — the viewer receives video/audio and
  sends loss-recovery feedback; the outbound TCP back-channel (annotations,
  control) is future work.
- **Windows** — the backends are cross-platform (SDL2/FFmpeg/tsnet everywhere;
  audio would swap ALSA for WASAPI), but only Linux is wired/tested so far.
