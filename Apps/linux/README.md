# Apps/linux — portable viewer core (Linux/Windows)

Shared **library** package that plugs concrete platform backends into the
portable `ViewerSession` data-plane core (`Packages/TailscreenKit`'s
`TailscreenViewer` target). Where the macOS app decodes with VideoToolbox,
renders with Metal, and plays audio through AVAudioEngine, these backends are:

| Role      | Backend                          | Seam it satisfies |
|-----------|----------------------------------|-------------------|
| Decode    | `FFmpegKit` (libavcodec)         | `VideoDecoding`   |
| Audio     | `ALSAKit` (libasound)            | `AudioSink`       |
| Transport | `TailscaleKit` (tsnet UDP)       | `receiveRTP` / `onControlToSend` / `tick` |

The concrete video **render** surface is *not* here — the runnable viewer is
the native GTK desktop app in **[`Apps/linux-gtk`](../linux-gtk)**, which owns a
`GtkGLArea` YUV renderer and reuses the two library targets below. (A prior SDL
CLI viewer was removed once the GTK viewer superseded it.)

All the receive-side *logic* (RTP demux, reassembly, NACK/PLI feedback,
receiver reports, audio decode) lives in the portable, unit-tested
`ViewerSession`. The code here is deliberately thin: adapters bridging the
backends to the protocol seams, plus a tsnet transport that pumps datagrams in
and ships control bytes out.

## Layout

```
Apps/linux/
├── Package.swift
├── Sources/
│   ├── TailscreenViewerCore/       # library — CI-testable, NO tsnet
│   │   ├── Adapters.swift          #   FFmpeg → VideoDecoding, ALSA → AudioSink
│   │   └── ThreadedAudioSink.swift #   off-thread ALSA writes (used by the GTK viewer)
│   │                               # (ViewerPipeline — the decoder+sink assembler —
│   │                               #  lives in TailscreenKit's TailscreenViewer target;
│   │                               #  it was Foundation-only and needn't drag in libav*)
│   └── TailscreenViewerTsnet/      # library — the tsnet transport
│       ├── TsnetTransport.swift    #   node bring-up + discovery + UDP run loop
│       └── ViewerBackChannel.swift #   outbound TCP control/annotation channel
└── Tests/TailscreenViewerCoreTests/
    └── PipelineIntegrationTests.swift  # real H.264 → RTP → decode → sink
```

The package is split so the decode→audio pipeline is provable in CI without the
tsnet/Go dependency: `TailscreenViewerCore` depends only on the A/V backends and
the portable core. `TailscreenViewerTsnet` adds the `TailscaleKit` dependency
(and thus the built `libtailscale.a`).

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

`swift test` builds and links the whole package (including `TailscreenViewerTsnet`),
so it needs `libtailscale.a` present — which also makes it the Linux link-check
for the tsnet transport. The `linux-viewer` CI job runs exactly this.

## Running the viewer

There is no executable here — build and run **[`Apps/linux-gtk`](../linux-gtk)**
(the native GTK viewer). See its README for the run instructions, including the
OrbStack-from-a-Mac setup. A live session needs a real tailnet (or a local
headscale), the same constraint as every tsnet path in this repo, so it can't
run in CI.

## Not here yet

- **Mic capture** — the viewer plays sharer/system audio (ALSA out); an ALSA
  *input* path for the mic is future work.
- **Windows** — the backends are cross-platform (FFmpeg/tsnet everywhere; audio
  would swap ALSA for WASAPI, render for a D3D swapchain — see
  `docs/viewer-windows-plan.md`), but only Linux is wired/tested so far.
