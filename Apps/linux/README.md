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
  pkg-config golang-go make gcc libc6-dev

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

## Not here yet

- **FEC ingest** — `ViewerSession` degrades to NACK-or-PLI until the deferred
  `FECGroupBuffer` work lands (tracked in `ViewerSession.swift`'s `TODO(fec)`).
- **Remote control / annotations send** — the viewer receives video/audio and
  sends loss-recovery feedback; the outbound TCP back-channel (annotations,
  control) is future work.
- **Windows** — the backends are cross-platform (SDL2/FFmpeg/tsnet everywhere;
  audio would swap ALSA for WASAPI), but only Linux is wired/tested so far.
