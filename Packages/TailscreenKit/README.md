# TailscreenKit

The platform-portable core of Tailscreen, in six targets/tiers:

- **`TailscreenProtocol`** — the port-7447 wire protocol (RTP
  packetization, framed TCP messages, UDP control bytes, helper/picker IPC
  payload types) plus the pure decision logic extracted from the async
  loops (NACK scheduling, retransmit budgeting, FEC codec/buffering,
  receiver-report accounting, receive-loop retry policy, remote-control
  gate/coalescing, zoom math, tuning constants). **No Apple frameworks and
  no dependencies** — Foundation (+ the stdlib `Synchronization` module)
  only.
- **`TailscreenTransport`** — the tsnet-facing layer
  (`TailscalePeerDiscovery`, `TailscaleIPNWatcher`, `TailscaleAuth`, and
  `TsnetNodeFactory` — the one node bring-up every site goes through, with
  explicit knobs for ephemerality, the `up()` timeout policy, and the
  interactive login-URL subscription). Depends on
  `TailscreenProtocol` and on `TailscaleKit` (the patched wrapper, which
  itself builds on Linux — see `Packages/TailscaleKit/Patches/022`).
  *Compiling* it needs only the checked-out submodule with patches applied
  (`make -C ../TailscaleKit apply-patches`); the built
  `libtailscale.a` is a link-time input that no library target links — but
  the `TailscreenSharerTests` test bundle is an executable and does link it
  (via `TailscreenSharer` → `TailscaleKit`), so *testing* the package needs
  the archive built (`make -C ../TailscaleKit`).
  Their Combine surface (`ObservableObject`/`@Published`, which mac
  Foundation re-exports) compiles on Linux via the shims in
  `PortabilityShims.swift` — including a `$prop.values`-compatible
  projected value, which `TailscalePeerDiscovery` consumes.
- **`TailscreenAudio`** — the Opus voice/system-audio codec
  (`OpusVoiceEncoder`, `OpusVoiceDecoder`, `OpusPCM`): the Float32↔Int16
  conversion + 960-sample (20 ms) framing over `OpusKit` (the local
  `systemLibrary` wrapper around libopus), plus the voice receive path's
  pure loss-resilience decision layer (`VoiceReceiveDecisions` — route
  demux, decoder-failure cooldown, wrap-aware gap policy, adaptive jitter
  sizing, concealment cap/fade, stale-SSRC eviction), extracted from the
  macOS `VoiceChannel` so both endpoints decide identically. The portable
  `VoiceDownlink` composes those decisions (concealing gaps with Opus's
  native PLC via `OpusVoiceDecoder.conceal()`), so the Linux/Windows
  receive path degrades under loss the way the mac one does.
  Foundation + OpusKit only, so it
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
  viewer plugs in the same FFmpeg decode with D3D11 render and WASAPI
  output. Depends on `TailscreenProtocol` + `TailscreenAudio` only.
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
  IPC wire and simply hadn't been named as a portability boundary. Also
  here: `SharerAskToShareCoordinator`, the sharer's ask-to-share flow (the
  long-lived idempotent-per-node control listener, the `ShareRequestInbox`,
  and the answer sequencing: reply on the arrival connection; accept =>
  pre-approve, then start) shared by all three hosts. Depends
  on `TailscreenProtocol` + `TailscreenTransport` + `TailscaleKit`.
- **`TailscreenViewerTsnet`** — the `@MainActor` tsnet-backed viewer
  transport (`TsnetTransport` + `ViewerBackChannel`) the Linux and Windows
  apps drive their viewers with: node bring-up (including the interactive
  browser-login URL off the IPN bus), peer discovery, the UDP media socket,
  the TCP back-channel, and the run loop that feeds `ViewerPipeline`. It
  lived in `Packages/TailscreenLinuxBackends` until the Windows app needed
  it; nothing in it was ever Linux-specific, and moving it here means
  consuming the transport no longer drags in a video decoder or an audio
  backend a host may implement differently. Like `TailscreenTransport`,
  compiling it needs only the patched libtailscale header —
  `libtailscale.a` is a link-time input for the executable. Depends on
  `TailscreenProtocol` + `TailscreenAudio` + `TailscreenTransport` +
  `TailscreenViewer` + `TailscaleKit`.

All six build and run on Linux; they're the libraries a non-macOS
Tailscreen viewer or sharer links against. See `plans/porting-plan.md` for
that roadmap.

## How it's put together

- The sources live **only here** — the macOS app consumes this package as
  a real SwiftPM dependency (`Apps/macOS/Package.swift` declares it;
  `Apps/macOS/Sources/ProtocolReexports.swift` `@_exported import`s the
  products so app code keeps using the types unqualified).
- Because the app crosses a module boundary, everything the app touches is
  `public` — including explicit memberwise initializers (Swift never
  synthesizes those as public). Test-only seams stay `internal`: the package
  suites use `@testable import TailscreenProtocol` /
  `@testable import TailscreenAudio` / `@testable import TailscreenViewer`.
  The sharer tier's decision surface needs no `@testable`: its extracted
  decision functions (`nextAdaptiveBitrate`, `fecSweepDecision`,
  `admissionDecision`, …) are `public` — they're the reusable part of the
  data plane, and a second host implementation is exactly who would want
  them — so most of `TailscreenSharerTests` imports the module plainly (the
  exception is `SharerAskToShareCoordinatorTests`, which uses `@testable`
  for the coordinator's internal reply-send seam). `TailscreenTransport` has no package tests;
  the macOS app's suite exercises it through the app's dependency.
- `Tests/TailscreenProtocolTests` began as a shallow smoke suite and now
  also holds the **migrated pure suites** — the loss-recovery/RTP/wire/util
  tests whose subject types live entirely in this package (FEC, NACK,
  retransmit, RR, RTP packet/buffer/audio, receive-loop policy, capture-helper
  wire, screen-share/share-response protocol, share lock, quality settings,
  instance naming, viewer zoom math, Opus codec, voice receive decisions, the multi-account
  `AccountProfileStore` incl. both hosts' migration paths); the viewer tier has
  its own `Tests/TailscreenViewerTests`. They run on Linux CI
  (`linux-protocol`). `Tests/TailscreenSharerTests` holds the sharer-tier
  decision suites (`CongestionDecisionTests`, `FECOverheadDecisionTests`,
  `PerViewerFairnessDecisionTests`, `HelperRestartDecisionTests`,
  `ViewerLifecycleDecisionTests`) — they consume the deliberately-public
  decision surface through a plain `import TailscreenSharer`, no `@testable`,
  and run on the same job — plus `SharerAskToShareCoordinatorTests` (which
  does use `@testable`, for the coordinator's internal reply-send seam).
  One suite about this package deliberately lives OUTSIDE it:
  `Packages/TailscreenDifferential` drives this package's stateful pipeline
  against the **public Go SDK** (`sdk/go` built as `libtailscreen.a`) with
  identical seeded input. It cannot be a test target here because a Go
  c-archive carries a whole Go runtime and two of them cannot share one
  binary (their cgo export symbols collide) — this package's test executable
  already links `libtailscale.a` through `TailscreenSharerTests`, so the
  suite that links `libtailscreen.a` needs its own package and test binary
  (`make test-differential`, CI's `linux-differential`). A suite belongs in the package iff it imports no
  Apple framework and references only package types; anything that mixes in a
  mac symbol (an Apple-framework import, an
  `AppState`/`VideoDecoder`/`VoiceChannel` decision, or a shared helper with a
  mac consumer like `LossyChannel` / `ParserFuzzHarness`) stays in the main
  repo's `Tests/TailscreenTests`, which exercises this package through the
  app's dependency.

## Build & test

```bash
make test-protocol   # from the repo root (applies TailscaleKit patches and
                     # builds libtailscale.a first — the sharer test bundle
                     # links the archive)
# or directly (after `make -C Packages/TailscaleKit`):
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
