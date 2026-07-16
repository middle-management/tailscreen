# TailscreenProtocol

The platform-portable core of Tailscreen, in two targets/tiers:

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
  itself builds on Linux — see `TailscaleKitPackage/Patches/022`).
  *Compiling* it needs only the checked-out submodule with patches applied
  (`make -C ../TailscaleKitPackage apply-patches`); the built
  `libtailscale.a` is a link-time input that nothing in this package links.
  Their Combine surface (`ObservableObject`/`@Published`, which mac
  Foundation re-exports) compiles on Linux via the shims in
  `PortabilityShims.swift` — including a `$prop.values`-compatible
  projected value, which `TailscalePeerDiscovery` consumes.

Both build and run on Linux; they're the libraries a future non-macOS
Tailscreen viewer or sharer links against. See `docs/porting-plan.md` for
that roadmap.

## How it's put together

- `Sources/TailscreenProtocol/*.swift` are **symlinks into `../Sources/`**
  (the same convention TailscaleKitPackage uses for its upstream). The
  macOS app compiles those files directly as part of the `Tailscreen`
  target; this package compiles the identical bytes a second time as a
  standalone module. There is exactly one copy of the code.
- The macOS app does **not** depend on this package (yet — flipping the
  app to consume it as a real dependency is a follow-up that needs a Mac,
  because it turns on access-control across a module boundary; see the
  porting plan).
- `Tests/TailscreenProtocolTests` is a deliberately shallow smoke suite
  proving the module *runs* (encode/decode/recover round trips) on Linux.
  The exhaustive wire-format, loss-recovery, and fuzz coverage lives in the
  main repo's `Tests/TailscreenTests`, which exercises these same sources.

## Build & test

```bash
make test-protocol   # from the repo root (applies TailscaleKit patches first)
# or directly (after `make -C TailscaleKitPackage apply-patches`):
PKG_CONFIG_PATH="$PWD/TailscaleKitPackage" \
  swift test --package-path TailscreenProtocolPackage  # macOS and Linux
```

CI's `linux-protocol` job (`.github/workflows/build.yml`) runs exactly this
inside a `swift:6.1-noble` container on every PR — that job is what
*enforces* the portability boundary.

## Rules for files in the portable set

1. **No Apple-framework imports.** Foundation, `Synchronization`, and
   `#if canImport(CoreGraphics)` (the CG geometry value types come from
   swift-corelibs-foundation on Linux) are the whitelist. No `os` (use
   `Synchronization.Mutex`, not `OSAllocatedUnfairLock`), no `Darwin`, no
   AppKit/VideoToolbox/CoreMedia/Combine.
2. **Adding a file to the set:** keep the real file in `Sources/`, add a
   relative symlink here (`ln -s ../../../Sources/Foo.swift Foo.swift`),
   and confirm `make test-protocol` still passes.
3. **A portable file may only reference other portable files.** If a
   declaration a portable file needs lives in a mac-bound file, move that
   declaration into a portable file first (same module on the mac side, so
   the move is invisible there) — that's how `VideoCodecTypes.swift`,
   `TailscreenWireTypes.swift`, and `TimeoutError` (in `Timeout.swift`)
   came to be.
4. **Wire changes still follow the registry rule:** a new wire byte means a
   `WireByteRegistryTests` row in the same commit (that suite lives in the
   main package).
