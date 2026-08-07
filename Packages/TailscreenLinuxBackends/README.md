# Packages/TailscreenLinuxBackends — Linux platform backends (viewer + sharer)

Shared **library** package that plugs concrete platform backends into the two
portable data-plane cores in `Packages/TailscreenKit` — `TailscreenViewer`
(`ViewerSession`) and `TailscreenSharer` (`TailscaleScreenShareServer`). Where
the macOS app decodes with VideoToolbox, renders with Metal, plays audio
through AVAudioEngine, and captures with ScreenCaptureKit, these backends are:

| Role      | Backend                          | Seam it satisfies |
|-----------|----------------------------------|-------------------|
| Decode    | `FFmpegKit` (libavcodec)         | `VideoDecoding`   |
| Audio out | `ALSAKit` (libasound)            | `AudioSink`       |
| Audio in  | `ALSAKit` (libasound)            | `BlockingPCMSource` |
| Transport | `TailscaleKit` (tsnet UDP)       | `receiveRTP` / `onControlToSend` / `tick` |
| **Capture + encode** | `X11CaptureKit` + `FFmpegKit` | **`CaptureEncoding`** |
| Input injection | `XTestInjectKit` (XTEST)   | `InputInjecting`  |

The concrete video **render** surface is *not* here — the runnable viewer is
the native GTK desktop app in **[`Apps/linux`](../../Apps/linux)**, which owns a
`GtkGLArea` YUV renderer and reuses the two library targets below. (A prior SDL
CLI viewer was removed once the GTK viewer superseded it.)

All the receive-side *logic* (RTP demux, reassembly, NACK/PLI feedback,
receiver reports, audio decode) lives in the portable, unit-tested
`ViewerSession`. The code here is deliberately thin: adapters bridging the
backends to the protocol seams, plus a tsnet transport that pumps datagrams in
and ships control bytes out.

## Layout

```
Packages/TailscreenLinuxBackends/
├── Package.swift
├── Sources/
│   ├── TailscreenViewerCore/        # library — CI-testable, NO tsnet
│   │   ├── Adapters.swift           #   FFmpeg → VideoDecoding, ALSA → AudioSink
│   │   ├── ALSAMicrophone.swift     #   ALSA in → BlockingPCMSource (the mic)
│   │   ├── ThreadedAudioSink.swift  #   off-thread ALSA writes (used by the GTK viewer)
│   │   └── ViewerInput.swift        #   GTK pointer/key events → wire InputEvent
│   │                                # (the FFmpeg decoder moved to
│   │                                #  Packages/TailscreenVideoFFmpeg — Windows needs
│   │                                #  it without ALSA/X11 — and is @_exported from
│   │                                #  Adapters.swift, so call sites are unchanged)
│   │                                # (ViewerPipeline — the decoder+sink assembler —
│   │                                #  lives in TailscreenKit's TailscreenViewer target;
│   │                                #  it was Foundation-only and needn't drag in libav*)
│   │                                # (the tsnet transport moved to TailscreenKit's
│   │                                #  TailscreenViewerTsnet target — the Windows app
│   │                                #  needs it and nothing in it was Linux-specific)
│   ├── TailscreenTestSharer/        # executable — synthetic sharer for local
│   │                                #   end-to-end runs (captures nothing)
│   ├── TailscreenSharerLinux/       # library — the SHARER engine + its backends
│   │   ├── LinuxShareSession.swift  #   the GTK app's share ENGINE (see below)
│   │   ├── SharerOverlaySurface.swift #  seam the GTK overlay reaches the engine through
│   │   ├── X11CaptureEncoder.swift  #   X11 capture + libavcodec → CaptureEncoding
│   │   └── X11InputInjecting.swift  #   XTEST → InputInjecting
│   ├── tailscreen-sharer-linux/     # executable — the real headless SHARER
│   └── tailscreen-viewer-probe/     # executable — headless viewer (asserts frames)
├── Tests/TailscreenViewerCoreTests/
│   ├── NodeIdentityTests.swift          # node label / state-dir derivation
│   ├── PipelineIntegrationTests.swift   # real H.264 → RTP → decode → sink
│   └── ViewerInputMappingTests.swift    # GTK event → wire InputEvent
└── Tests/TailscreenSharerLinuxTests/
    ├── CaptureEncoderTests.swift        # real capture → encode → decode (Xvfb)
    └── LinuxShareSessionTests.swift     # the share engine, headless (no tsnet)
```

`LinuxShareSession` is the GTK app's share engine — server lifecycle, access
control, the drawing latch, voice, and the idle control listener + ask-to-share
inbox — and the Linux twin of `TailscreenSharerWGC.WindowsShareSession`. It
lives here rather than in `Apps/linux` so Linux CI can test it headless. The
app's `SharerModel` is the thin observable façade over it. One deliberate
difference from Windows: the engine is `@MainActor` rather than lock-guarded,
which is what keeps the grant-generation `isStale` guard meaningful.

The package is split so the decode→audio pipeline is provable in CI without the
tsnet/Go dependency: `TailscreenViewerCore` depends only on the A/V backends and
the portable core. The transport lives in TailscreenKit as
`TailscreenViewerTsnet`, which is what adds the `TailscaleKit` dependency (and
thus the built `libtailscale.a`) for the executables here that consume it.

## Build & test

Needs a Swift 6 toolchain and system dev libraries:

```bash
# Debian/Ubuntu
sudo apt-get install -y \
  libavcodec-dev libavutil-dev libasound2-dev libopus-dev \
  pkg-config golang-go make gcc libc6-dev \
  libxml2 libcurl4-openssl-dev libedit2 libpython3-dev libz3-dev  # Swift runtime deps

# libtailscale.a (the Tsnet target links it; the Core library + test don't)
make -C ../../Packages/TailscaleKit

# Build everything + run the pipeline integration test
PKG_CONFIG_PATH="$PWD/../../Packages/TailscaleKit" swift test --package-path .
```

`swift test` builds and links the whole package (including the executables that
pull in `TailscreenViewerTsnet`), so it needs `libtailscale.a` present — which
also makes it the Linux link-check for the tsnet transport. The `linux-viewer`
CI job runs exactly this.

## Running the viewer

The viewer executable is **[`Apps/linux`](../../Apps/linux)** (the native GTK
app). See its README for the run instructions, including the OrbStack-from-a-Mac
setup. A live session needs a real tailnet (or a local headscale), the same
constraint as every tsnet path in this repo, so it can't run in CI.

## `TailscreenTestSharer` — synthetic sharer for end-to-end runs

This predates the Linux sharer: when the only real sharer was macOS's
(ScreenCaptureKit), everything past "the node comes up" on this side was only
compile-gated. `TailscreenTestSharer` stands in for one — a second tsnet node
speaking the **sharer half** of the wire protocol, so the whole viewer path runs
on one Linux box. It serves **real H.264** (libavcodec, a moving test pattern),
so the viewer's FFmpeg decode and GL render do genuine work.

It is a development/test tool, **not** a product sharer: it captures nothing and
admits every viewer (no approval gate, allow/deny store, or SSRC anti-spoof —
all of which the macOS sharer implements and its own suites cover).

```bash
# 1. local control plane (writes the env exports)
eval "$(./scripts/e2e-up-native.sh)"

# 2. synthetic sharer — note the 100.64.x.y address it prints
swift run --package-path Packages/TailscreenLinuxBackends TailscreenTestSharer --fps 10 --size 640x360

# 3. viewer, dialing that address (separate state dir!)
cd Apps/linux && swift run tailscreen 100.64.0.2 \
    --state-dir /tmp/viewer-state

./scripts/e2e-down-native.sh   # when done
```

Each node needs its **own** `--state-dir`: two tsnet nodes sharing one directory
reuse a machine key and won't see each other. Verified this way: discovery,
metadata (the sharing chip), HELLO/admission, RTP video → decode → GL render,
window-grow-to-video, the caps-gated toolbars, and the annotation / control /
input back-channel paths (the sharer logs each inbound op and relays annotations
back). Still local-only — it can't run in CI for the usual tsnet reason.

## The sharer backend

`TailscreenSharerLinux.X11CaptureEncoder` satisfies `CaptureEncoding`: it
captures the X root window, encodes with libavcodec, and honours the three
congestion levers (`setBitrate` / `requestKeyframe` / `setFrameInterval`).
Everything above it — admission, RTP fan-out, NACK/FEC, congestion control — is
the portable `TailscaleScreenShareServer`, unchanged.

Unlike macOS there is **no helper subprocess**: `replayd`'s slot-release
behaviour is the only reason capture is isolated there, and Linux has no
equivalent coupling (`plans/porting-plan.md` #10), so capture runs in-process
and `stop()` genuinely stops it.

Current limits of **this** backend, deliberately explicit: display shares only
(window/app selections are *refused*, not silently widened to the whole screen
— sharing one window is the portal's job, `Packages/TailscreenSharerPortal`),
X11 only, no system-audio capture, no `onPreviewImage` (the sharer's preview goes up as
raw pixels through `onPreviewThumbnail` instead — that seam carries *encoded*
bytes for the mac helper's sake, and there is no process boundary here to pay
for), software encoders only
(hardware VA-API/NVENC needs `AVHWFramesContext` upload this path doesn't do).

### Running it end to end

`tailscreen-sharer-linux` is a real (headless) sharer; `tailscreen-viewer-probe`
is a headless viewer that decodes and asserts instead of drawing. Together they
make the Linux→Linux path scriptable:

```bash
./scripts/e2e-linux-sharer.sh      # headscale + Xvfb + both nodes + assertions
```

That script brings its own control plane and display up and tears them down, so
it's a single command from a clean checkout. A passing run looks like:

```
[sharer] READY hostname=ts-sharer ip4=100.64.0.1 fps=10
[sharer] viewers: 1 [100.64.0.2]
[probe]  admitted by sharer (serverCaps=23)
[probe]  first frame 1280x720
[probe]  PROBE_OK frames=16 size=1280x720 nonUniform=true
```

`nonUniform=true` is the load-bearing part: it means the decoded luma actually
varies, so the frames carry real captured pixels rather than a flat rectangle
that would satisfy a frame count. `serverCaps=23` is
`nack|receiverReport|fec|annotations` — note `remoteControl` (bit 3) is
**absent**, because this host supplies no `InputInjecting` backend and the
portable server withholds the bit rather than inviting requests it can't serve.

Local-only, for the usual tsnet reason: CI can't bring a tailnet up.

To drive it by hand instead (e.g. to watch in the GTK viewer):

```bash
eval "$(./scripts/e2e-up-native.sh)"
DISPLAY=:0 swift run --package-path Packages/TailscreenLinuxBackends tailscreen-sharer-linux \
    --hostname ts-sharer --state-dir /tmp/sharer-state
cd Apps/linux && swift run tailscreen 100.64.0.1 \
    --state-dir /tmp/viewer-state
```

## Not here

- **The ScreenCast portal** — the Wayland-capable capture path lives in
  `Packages/PortalCaptureKit` (the shim) and `Packages/TailscreenSharerPortal`
  (its `CaptureEncoding` backend), separate packages so consuming the X11
  sharer — or running viewer-only — doesn't put libdbus and libpipewire on the
  link line. `Apps/linux` picks between the two at share time via
  `CaptureBackendSelection`. See `Packages/X11CaptureKit/README.md` for why X11
  came first (CI can run it; the portal never can).
- **The Windows backends** — `WGCCaptureKit` / `TailscreenSharerWGC` /
  `WASAPIKit` / `SendInputKit` and friends, each its own package for the same
  reason. The shared halves (FFmpeg decode, the tsnet transport, the portable
  cores) are consumed from `Packages/TailscreenKit` and
  `Packages/TailscreenVideoFFmpeg` by both platforms.

Mic capture *is* here: `ALSAMicrophone.swift` adapts ALSA input to the portable
`BlockingPCMSource` seam, the counterpart of `WASAPIKit`'s recorder.
