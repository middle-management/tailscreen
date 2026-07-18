# TailscreenKit

The platform-portable core of Tailscreen, in three targets/tiers:

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
  itself builds on Linux — see `TailscaleKit/Patches/022`).
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

All three build and run on Linux; they're the libraries a future non-macOS
Tailscreen viewer or sharer links against. See `docs/porting-plan.md` for
that roadmap.

## How it's put together

- The sources live **only here** — the macOS app consumes this package as
  a real SwiftPM dependency (`Package.swift` at the repo root declares it;
  `Sources/ProtocolReexports.swift` `@_exported import`s all three products
  so app code keeps using the types unqualified).
- Because the app crosses a module boundary, everything the app touches is
  `public` — including explicit memberwise initializers (Swift never
  synthesizes those as public). Test-only seams stay `internal`: the test
  suite uses `@testable import TailscreenProtocol` /
  `@testable import TailscreenTransport` / `@testable import TailscreenAudio`.
- `Tests/TailscreenProtocolTests` is a deliberately shallow smoke suite
  proving the module *runs* (encode/decode/recover round trips) on Linux.
  The exhaustive wire-format, loss-recovery, and fuzz coverage lives in the
  main repo's `Tests/TailscreenTests`, which exercises this package through
  the app's dependency.

## Build & test

```bash
make test-protocol   # from the repo root (applies TailscaleKit patches first)
# or directly (after `make -C TailscaleKit apply-patches`):
PKG_CONFIG_PATH="$PWD/TailscaleKit" \
  swift test --package-path TailscreenKit  # macOS and Linux
```

CI's `linux-protocol` job (`.github/workflows/build.yml`) runs exactly this
inside a `swift:6.1-noble` container on every PR — that job is what
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
