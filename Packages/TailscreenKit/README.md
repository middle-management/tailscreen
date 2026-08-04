# TailscreenKit

The platform-portable core of Tailscreen, in five targets/tiers:

- **`TailscreenProtocol`** — the port-7447 wire protocol (RTP
  packetization, framed TCP messages, UDP control bytes, helper/picker IPC
  payload types) plus the pure decision logic extracted from the async
  loops (NACK scheduling, retransmit budgeting, FEC codec/buffering,
  receiver-report accounting, receive-loop retry policy, remote-control
  gate/coalescing, zoom math, tuning constants). **No Apple frameworks and
  no dependencies** — Foundation (+ the stdlib `Synchronization` module)
  only.
- **`TailscreenTransport`** — the tsnet-facing layer
  (`TailscalePeerDiscovery`, `TailscaleIPNWatcher`). Depends on
  `TailscreenProtocol` and on `TailscaleKit` (the patched wrapper, which
  itself builds on Linux — see `Packages/TailscaleKit/Patches/022`).
  *Compiling* it needs only the checked-out submodule with patches applied
  (`make -C ../TailscaleKit apply-patches`); the built
  `libtailscale.a` is a link-time input that nothing in this package links.
  Their Combine surface (`ObservableObject`/`@Published`, which mac
  Foundation re-exports) compiles on Linux via the shims in
  `PortabilityShims.swift` — including a `$prop.values`-compatible
  projected value, which `TailscalePeerDiscovery` consumes.
- **`TailscreenAudio`** — the Opus voice/system-audio codec
  (`OpusVoiceEncoder`, `OpusVoiceDecoder`, `OpusPCM`): the Float32↔Int16
  conversion + 960-sample (20 ms) framing over `OpusKit` (the local
  `systemLibrary` wrapper around libopus). Foundation + OpusKit only, so it
  builds on Linux/Windows too; a future non-macOS client reuses the exact
  codec and supplies its own platform audio I/O (`VoiceChannel` /
  `SystemAudioTap` are the mac-side consumers). It `@_exported`s OpusKit so
  `Opus.Application` is visible to consumers. Kept out of
  `TailscreenProtocol` so that tier stays dependency-free. Building/testing
  it needs libopus present (`apt install libopus-dev pkg-config` on Linux,
  `brew install opus` on macOS — resolved via pkg-config).
- **`TailscreenViewer`** — the host-agnostic *viewer* data plane:
  `ViewerSession` (inbound RTP → decoded frames + outbound HELLO/NACK/PLI/RR
  feedback) behind the `VideoDecoding` / `VideoSink` / `AudioSink` seams,
  `ViewerPipeline` (assembles a session from host-supplied decoder/sink
  factories), and `FrameStore` (the lock + value-type-COW hand-off a renderer
  polls from its UI thread). It owns no socket, thread, or timer, and no
  concrete codec/renderer/audio backend — the Linux viewer plugs FFmpeg
  decode, GL render, and ALSA output in behind the protocols; the Windows
  viewer will plug in D3D and WASAPI. Depends on `TailscreenProtocol` +
  `TailscreenAudio` only.
- **`TailscreenSharer`** — the host-agnostic *sharer* data plane:
  `TailscaleScreenShareServer` — viewer admission and the access-policy
  gate, RTP fan-out, NACK/retransmit/FEC, the congestion + per-viewer
  fairness controllers, the idle sweep, the capture-restart budget and
  hung-backend watchdog, and the remote-control grant gate — behind two
  seams in `SharerBackends.swift`: `CaptureEncoding` (capture + encode) and
  `InputInjecting` (remote-control injection). Neither the capture stack nor
  the injector is here: macOS plugs in its `--capture-helper` subprocess and
  `CGEvent` injector, and a Linux sharer plugs in X11/portal capture +
  libavcodec. `CaptureEncoding` is deliberately shaped like
  `CaptureHelperWire`'s `OutType`/`InType` — the seam already existed as an
  IPC wire and simply hadn't been named as a portability boundary. Depends
  on `TailscreenProtocol` + `TailscreenTransport` + `TailscaleKit`.

All five build and run on Linux; they're the libraries a future non-macOS
Tailscreen viewer or sharer links against. See `plans/porting-plan.md` for
that roadmap.

## How it's put together

- The sources live **only here** — the macOS app consumes this package as
  a real SwiftPM dependency (`Apps/macOS/Package.swift` declares it;
  `Apps/macOS/Sources/ProtocolReexports.swift` `@_exported import`s the
  products so app code keeps using the types unqualified).
- Because the app crosses a module boundary, everything the app touches is
  `public` — including explicit memberwise initializers (Swift never
  synthesizes those as public). Test-only seams stay `internal`: the test
  suite uses `@testable import TailscreenProtocol` /
  `@testable import TailscreenTransport` / `@testable import TailscreenAudio` /
  `@testable import TailscreenSharer`. The sharer tier is the one place this
  rule bends: its extracted decision functions (`nextAdaptiveBitrate`,
  `fecSweepDecision`, `admissionDecision`, …) are `public` even though only
  tests call them today — they're the reusable part of the data plane, and a
  second host implementation is exactly who would want them.
- `Tests/TailscreenProtocolTests` began as a shallow smoke suite and now
  also holds the **migrated pure suites** — the loss-recovery/RTP/wire/util
  tests whose subject types live entirely in this package (FEC, NACK,
  retransmit, RR, RTP packet/buffer/audio, receive-loop policy, capture-helper
  wire, screen-share/share-response protocol, share lock, quality settings,
  instance naming, viewer zoom math, Opus codec, the multi-account
  `AccountProfileStore` incl. both hosts' migration paths). They run on Linux CI
  (`linux-protocol`). A suite belongs here iff it imports no Apple framework
  and references only package types; anything that mixes in a mac symbol (an
  Apple-framework import, a server/`AppState`/`VideoDecoder`/`VoiceChannel`
  decision, or a shared helper with a mac consumer like `LossyChannel` /
  `ParserFuzzHarness`) stays in the main repo's `Tests/TailscreenTests`, which
  exercises this package through the app's dependency.

## Build & test

```bash
make test-protocol   # from the repo root (applies TailscaleKit patches first)
# or directly (after `make -C Packages/TailscaleKit apply-patches`):
PKG_CONFIG_PATH="$PWD/Packages/TailscaleKit" \
  swift test --package-path Packages/TailscreenKit  # macOS and Linux
```

CI's `linux-protocol` job (`.github/workflows/build.yml`) runs exactly this
inside a `swift:6.3-noble` container on every PR — that job is what
*enforces* the portability boundary.

## Rules for files in the portable set

1. **No Apple-framework imports.** Foundation, `Synchronization`, and
   `#if canImport(CoreGraphics)` (the CG geometry value types come from
   swift-corelibs-foundation on Linux) are the whitelist. No `os` (use
   `Synchronization.Mutex`, not `OSAllocatedUnfairLock`), no `Darwin`
   (use a Glibc shim behind `canImport`), no
   AppKit/VideoToolbox/CoreMedia/Combine (`PortabilityShims.swift`
   provides `ObservableObject`/`@Published` stand-ins off-Apple).
2. **Adding a file to the set:** `git mv` it from `Sources/` into the
   right target here, mark what the app uses `public` (explicit inits for
   app-constructed structs — Swift never synthesizes memberwise inits as
   public), and confirm `make test-protocol` and `make build` still pass.
3. **A portable file may only reference portable files.** If a declaration
   it needs lives in a mac-bound app file, move that declaration into this
   package first — that's how `VideoCodecTypes.swift`,
   `TailscreenWireTypes.swift`, and `TimeoutError` (in `Timeout.swift`)
   came to be.
4. **Wire changes still follow the registry rule:** a new wire byte means a
   `WireByteRegistryTests` row in the same commit (that suite lives in the
   main package).
