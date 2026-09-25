---
paths:
  - "Packages/TailscreenKit/**"
  - "Packages/TailscreenHubUI/**"
  - "Packages/TailscreenL10n/**"
  - "Packages/{OpusKit,FFmpegKit,TailscreenVideoFFmpeg}/**"
---

# Portable protocol core (TailscreenKit) and the shared packages

Package rules (no Apple frameworks; what must be `public`; how to move a file in) are canonical in **`Packages/TailscreenKit/README.md`** — read it before touching the package. `make test-protocol` (macOS or Linux) is CI's `linux-protocol` job and enforces the portability boundary.

The app consumes the package as a real SwiftPM dependency; `Apps/macOS/Sources/ProtocolReexports.swift` `@_exported import`s it so app code uses the types unqualified. Everything the app touches must therefore be `public`, including explicit memberwise inits (Swift never synthesizes those as public). Test-only seams stay `internal`, reached via `@testable import`.

## Tiers, in dependency order

1. **`TailscreenProtocol`** — dependency-free (Foundation only, `#if canImport(CoreGraphics)` ok). Wire protocol + pure decision logic (NACK/FEC/RR/retransmit/remote-control policy). Also lives here because all three apps or both endpoints need it:
   - **`Guarded`** — the lock type; see Pitfalls/rule 2.
   - **`ViewerSessionLifecycle`** / **`NodeBringUpPhase`** / **`ShareBringUpPhase`** — portable state machines shared by all three hub UIs. `ViewerSessionLifecycle.begin` returns a `ViewerSessionID` every async transition must carry back (an old callback can outlive a replacement session in the same phase). **Gate share state on `isLive`/`canStart`, never `== .idle`** — a `failed` share reads as live forever under a `!= .idle` gate (this shipped as a real bug: locked account switching, dead peer rows, silenced notices).
   - **`I420Converter`** / **`ThumbnailScaler`** — pixel-format arithmetic with callers on both the viewer and the non-mac sharer sides; also the kind of bug (channel swap, stride) that fails silently, so it lives where Linux CI can test it.
   - **`Diagnostics/`** — the session diagnostics recorder/registry/redaction/merge; see `.claude/rules/diagnostics.md`.
2. **`TailscreenTransport`** — deps: `TailscreenProtocol` + `TailscaleKit`. tsnet bring-up (`TsnetNodeFactory` — the ONE node bring-up path; route new bring-up through it, don't hand-roll), peer discovery, `TailscaleAuth`, `TailscreenControlListener`/`FramedControlChannel` (framed-TCP, shared by tailnet and guest listeners). Compiling needs only the patched libtailscale **header**; `libtailscale.a` is link-time only (but `TailscreenSharerTests` links it, so testing needs it built). Combine surface (`ObservableObject`/`@Published`) is shimmed for Linux in `PortabilityShims.swift`. `TailscaleIPNWatcher` self-heals a dead IPN-bus stream with backoff.
3. **`TailscreenAudio`** — deps: Foundation + OpusKit + `TailscreenProtocol` only (edge points at the dependency-free tier, keeping it clean). Opus codec, mic capture seam, `VoiceUplink`/`VoiceDownlink` (loss-resilient: PLC concealment, jitter target, stale-SSRC eviction), `VoiceMixer` (sums same-slot SSRCs — required because every host has one playback queue), `SharerVoiceSession`/`VoiceLatch` (mute-state value types; **one type per direction, not per endpoint** — sharer and viewer voice differ only in SSRC). Builds on Linux; needs libopus (`apt install libopus-dev` / `brew install opus`).
4. **`TailscreenViewer`** — deps: `TailscreenProtocol` + `TailscreenAudio` only. The viewer data plane: `ViewerSession` (RTP in → decoded frames/audio + HELLO/NACK/PLI/RR out), the `VideoDecoding`/`VideoSink`/`AudioSink` protocols, `ViewerPipeline`, `FrameStore`, `ThreadedAudioSink`, `MonoPCMConverter`. Owns no socket/thread/timer — host feeds bytes + a clock. Also the shared **decode-failure escalation ladder** (`DecodeRecovery.swift`, opt-in via `onDecoderResetNeeded`/`onDecodeFatal`). `makeColorBarsFrame()` — read its doc comment before asserting against it: only bars 0/1 are exact; use relative predicates.
5. **`TailscreenSharer`** — deps: `TailscreenProtocol` + `TailscreenTransport` + `TailscaleKit`. The host-agnostic sharer data plane (`TailscaleScreenShareServer`): admission, RTP fan-out, NACK/FEC, congestion/fairness, capture-restart watchdog, remote-control gate — behind two seams in `SharerBackends.swift`: **`CaptureEncoding`** (capture+encode) and **`InputInjecting`**. The server takes a capture **factory**, not an instance (macOS restarts need a fresh helper process). `ScreenShareCaps.remoteControl` is advertised iff an `InputInjecting` backend was supplied. Also here: **`SharerSessionCore`** (a *value type* — each host holds it under its own guard: actor on Linux, `NSLock` on Windows), **`SharerLinkSession`** (share-by-token lifecycle, an actor), **`SharerAskToShareCoordinator`** (the ask-to-share flow all three hosts share).
6. **`TailscreenViewerTsnet`** — deps: all of the above + `TailscaleKit`. `TsnetTransport` + `ViewerBackChannel`: node bring-up incl. browser-login, discovery, UDP media socket, TCP back-channel, and the guest-tunnel path (`ViewerConfig.guestToken`). `@MainActor`-isolated. **The socket read must stay `Task.detached`** — a plain `Task { }` inherits MainActor and starves the read loop under load (measured 15.6 datagrams/s against a stream sending hundreds — a blank window with a healthy-looking wire). Needs only the libtailscale header to compile.

## Migrated test suites

The package's `TailscreenProtocolTests`/`TailscreenSharerTests`/`TailscreenViewerTests` targets carry the pure decision/RTP/wire suites (run by `linux-protocol`). Do not hand-maintain a roster here — use `ls Packages/TailscreenKit/Tests/…` or the **`test-catalog`** skill to find or place a suite. One suite lives deliberately *outside* the package: `Packages/TailscreenDifferential` drives the package's stateful pipeline against the public Go SDK (`sdk/go`, as `libtailscreen.a`) — its own package because two Go c-archives can't share one binary. A suite belongs in the package iff it imports no Apple framework and touches only package types; anything mixing in a mac symbol (`AppState`, `VideoDecoder`, or a shared helper like `LossyChannel`/`ParserFuzzHarness` with a mac consumer) stays in `Apps/macOS/Tests/TailscreenTests`. The Windows share engine's suite lives in its own package, `Packages/TailscreenSharerWGC` (runs on `linux-viewer`), since `Apps/windows` has no test target.

## Neighbouring shared packages

- **`TailscreenHubUI`** — the hub look shared by the GTK and WinUI apps (header, screen rows, login/share cards, `ViewerNoticeBanner`, `AnnotationToolbar`, `RemoteControlBar`). Deps: SwiftCrossUI + `TailscreenProtocol` only — no transport type, so Linux CI typechecks it on the Windows app's behalf. A live share does **not** render inside `HubSignInPane` — each host swaps it out for its sharing view.
- **`TailscreenL10n`** — the string catalog all three apps read (`L(_:)`). A separate package (not a TailscreenKit tier) because `TailscreenHubUI` needs it without pulling in RTP machinery. Foundation only. Deliberately not `String(localized:)`/`Bundle.module` — see `.claude/rules/localization.md`.
- **`OpusKit`** — systemLibrary wrapper over libopus.
- **`FFmpegKit`** — systemLibrary wrapper over libavcodec (portable viewer decode + Linux sharer encode; not used by the mac app).
- **`TailscreenVideoFFmpeg`** — libavcodec behind portable seams (decoder target + `FFmpegCaptureEncoderBase` for the X11/WGC/portal encoders). Own package so `linux-protocol` doesn't need libavcodec.

## Pitfalls

- **A new lock-guarded type passes `linux-tsan` without ever being checked.** `Synchronization.Mutex` is invisible to TSan (it reads every `withLock` body as unsynchronised) — use **`Guarded`** instead, a one-word change. And if no test touches the type from multiple threads, the sanitiser observes nothing either way, so a genuinely multi-threaded type needs a test that hammers it from several threads. See `.claude/rules/testing.md`.
- **`linux-protocol` fails after touching a package file** — an Apple-only dependency snuck into `Packages/TailscreenKit/Sources/`. Keep it Foundation-only or move the piece into the app target. Reproduce with `make test-protocol`.
- **App fails to compile against a package type** ("initializer is inaccessible") — the declaration is `internal`. Mark what the app needs `public` (explicit inits too).
- **`make test-protocol` fails on macOS but `linux-protocol` is green** — a test asserted platform-specific *Foundation* behavior (e.g. `URL(fileURLWithPath:)` on a Windows-shaped path parses differently per platform). These suites run on all three platforms; use fixtures every platform's Foundation agrees on.

The Linux/Windows roadmap this enables lives in `plans/porting-plan.md`.
