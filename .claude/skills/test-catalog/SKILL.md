---
name: test-catalog
description: Catalog of Tailscreen's extracted pure-decision test suites, the test-only seams they reach through, and which package a new suite belongs in. Use when adding, moving, or extending a test — especially when extracting a pure decision out of an async loop, wiring a new test-only seam, or deciding whether a suite goes in the portable package or the macOS app target.
---

# Tailscreen test catalog

Reference for adding or moving a test. Running tests, the E2E surfaces, env-var
affordances and the impairment harness live in `.claude/rules/testing.md`,
which loads automatically for test files — read that first if you just need to
run something. This file is about where new test code goes and how it reaches
the code it tests.

## The extract-the-decision pattern

Most of this repo's async/stateful machinery (server sweep loops, capture
backends, notification delivery) can't be driven end-to-end in CI: it needs a
live capture helper, a real display, a consent dialog, or a socket. The fix
used throughout is to pull the actual **decision** — the pure function that
looks at some inputs and returns a verdict — out of the loop into a
`static func` or a free function/struct with no I/O, and test *that*
exhaustively, while the loop itself just calls it.

Canonical example: `TailscaleScreenShareServer.nextAdaptiveBitrate` is the
loss/recovery bitrate math extracted from the live congestion sweep, which
no-ops without a capture helper attached. `AdaptiveBitrateTests` drives the
function directly with no tsnet, no helper, no sockets.

Use this pattern whenever:
- the surrounding code is a loop/timer/callback that only fires with a live
  transport, display, or user gesture, so an E2E test can't exercise its
  branches;
- a wrong answer would be **silent** — the surrounding code still runs, a
  screen still updates, but with the wrong value (these are the bugs worth a
  suite; a bug that crashes doesn't need one).

How to structure it:
1. Move the branching logic into a `static func` (or a small value
   type/struct) that takes plain values in and returns a plain value out — no
   captured mutable state, no `self` unless `self` is itself the pure state
   being decided over (see `SharerSessionCore`, a value type for exactly this).
2. If the decision needs time, take an explicit clock parameter (`nowNs`)
   rather than reading the wall clock, so tests can hit exact boundaries
   instead of sleeping. This is used pervasively (`VoicePathTests`,
   `AnnotationStoreTests`, `DiagnosticsTransportSamplerTests`, ...).
3. Give the surrounding stateful code a **seam** to call the pure function
   through, or to observe its own outputs for testing (see below) — don't
   duplicate the decision inline.
4. Name the test file `<Subject>Tests` or `<Subject>DecisionTests` and put it
   in the target the decision requires (see "Where a suite lives").
5. Assert both directions when a decision has two silent failure modes (too
   eager AND too late/never) — see `BitDepthCapabilityDecisionTests` or
   `DiagnosticsRedactionTests` for the shape.

## Where a new suite lives

Pick the target by what the subject type imports, not by what package the file
happens to sit in today:

| Subject touches | Target | Import |
|---|---|---|
| Only Foundation + `TailscreenProtocol`/`TailscreenAudio` types | `Packages/TailscreenKit/Tests/TailscreenProtocolTests` | plain, or `@testable import TailscreenProtocol`/`TailscreenAudio` for internal seams |
| `TailscaleScreenShareServer` decisions (sharer tier) | `Packages/TailscreenKit/Tests/TailscreenSharerTests` | plain `import TailscreenSharer` — the decision surface is deliberately `public`; `@testable` only for the couple of suites that reach an internal seam (`SharerAskToShareCoordinatorTests`, `ViewerLabelTests`) |
| `ViewerSession`/viewer data-plane decisions | `TailscreenViewerTests` (same package) | plain, or `@testable` for internal seams |
| The shared string catalog (`L("…")` keys) | `Packages/TailscreenL10n/Tests` | scans all four source trees; put string/catalog suites here, not per-app |
| A Linux-only backend (X11/portal/ALSA/XTEST/hotkeys) | that package's own `Tests/` (e.g. `TailscreenSharerPortal`, `TailscreenLinuxBackends`) | — |
| The Windows share engine or a Windows-only backend | `Packages/TailscreenSharerWGC/Tests` or the relevant Windows package (`WinNotifyKit`, ...) — `Apps/windows` itself has no test target | — |
| FFmpeg-backed capture/decode scaffolding | `Packages/TailscreenVideoFFmpeg/Tests` | — |
| Anything importing an Apple framework (AppKit/ScreenCaptureKit/VideoToolbox/CoreAudio), `AppState`/`VideoDecoder` decisions, or the impairment/fuzz cluster (`RTPLossyChannelTests`, `ParserFuzzTests`, `SoakTests`, whose `LossyChannel`/`ParserFuzzHarness` helpers still have mac consumers) | `Apps/macOS/Tests/TailscreenTests` | `@testable import Tailscreen` |

Rule of thumb: if the subject type could theoretically run on Linux, it
belongs in a portable package test target so `linux-protocol`/`linux-viewer`
run it on every PR — don't leave portable logic pinned only by the mac target.
`make test-protocol` reproduces the portable suites locally (works on macOS
too) and is the fast way to check a new suite compiles Foundation-only before
pushing.

`@testable` vs plain import: decision functions in `TailscreenSharer` and most
of `TailscreenProtocol`'s extracted decisions are deliberately `public` so
suites import plainly — that's a repo convention, not an accident (see the
`TailscreenKit` package README's public-surface rule). Reach for `@testable`
only when the seam itself is genuinely internal (a reply-send hook, a
non-public memberwise init) rather than as a substitute for making the right
thing public.

## Test-only seams (non-obvious ones, verbatim names)

These exist purely so a test can observe or drive something the production
call sites never need to:

- **`onXForTesting` callbacks** on `TailscaleScreenShareServer` and
  `TailscaleScreenShareClient` — fire on the real event (PLI recorded, NACK
  served, FEC parity sent, control request recorded, decoded frame, input
  event admitted, annotation broadcast) with no socket needed to observe it.
  Pattern: `on<Event>ForTesting`.
- **`broadcastForTesting` / `broadcastSystemAudioForTesting`** — inject a
  frame/AU into the sharer's fan-out without a capture helper.
- **`grantBypassesAccessibilityForTesting`** — skips the Accessibility-TCC
  check so a remote-control grant can be exercised headlessly.
- **`decodeParameterSets`, `isCorrupt`, pure `static func` decisions** (see the
  long list in git history/`portable-packages.md` if you need the exhaustive
  roster) — most decision logic is exposed as a plain internal or public
  static function; find these with `rg 'ForTesting|@testable' <package>`
  rather than memorizing names, since new ones are added routinely.
- **`startWatching(subscriber:)`** on `TailscaleIPNWatcher` — internal seam,
  swaps the real LocalAPI bus for a fake `Subscriber`; needs `@testable`.
- **Explicit clock parameters** (`nowNs`, `tick(nowNs:)`) — the standard way
  to make time-based decisions deterministic; look for one before reaching for
  `sleep` in a new test.
- **`DiagnosticsCenter.shared`** is a process-wide singleton — suites that
  install into it must reset it in `tearDown`.
- **Env vars for test control** (see `.claude/rules/testing.md`'s full table):
  `TAILSCREEN_OPEN_DOOR=1` (skip approval gate), `TAILSCREEN_AUTOSHARE_DISPLAY=1`
  (picker-helper short-circuit), `TAILSCREEN_FORCE_STREAM=1` (force TCP-only
  transport profile), `TAILSCREEN_HELPER_EXE=<path>` (override helper spawn
  path under xctest), `TAILSCREEN_SOAK=1` (opt into the nightly fuzz/impairment
  tier), `TAILSCREEN_RUN_PICKER_LIFECYCLE_TEST=1` (opt into the on-screen
  picker UI test).

## Hard rules and pitfalls

- **Every wire byte needs a `WireByteRegistryTests` row, added in the same
  commit, never renumbered once shipped.** Symptom of skipping it: nothing
  fails locally, but a future byte collides silently. Same rule, same
  reasoning, for diagnostics event names (`DiagnosticEventNameTests`) — a
  rename there breaks an external reader invisibly since the call site still
  compiles.
- **Never lock new state with `Synchronization.Mutex`.** ThreadSanitizer
  cannot see through it — it reports a false race *inside* the lock body on
  correct code, and worse, `linux-tsan` passing says nothing about a
  `Mutex`-guarded type at all: it's invisible to the gate, not merely noisy.
  Use `TailscreenProtocol.Guarded` (same `withLock { $0 … }` shape over an
  `NSLock`) instead — a one-word change at the declaration, none at call
  sites. A bare `NSLock` beside the state is still fine; `Guarded` just also
  makes the state unreachable without it.
- **A lock nothing exercises concurrently proves nothing under TSan.** The
  sanitiser only reports races it watches execute, so a thread-safe type with
  a single-threaded suite passes `linux-tsan` without ever being checked. If
  you add a genuinely multi-threaded type, add a case that hammers it from
  several threads and asserts an interleaving-independent invariant (never a
  particular ordering) — see `RTPBufferPoolTests` and `RetransmitBufferTests`
  for the pattern.
- **`CVPixelBuffer` is not `Sendable`.** Convert to `CGImage` before hopping to
  `@MainActor` in a test that touches capture output.
- **A portable-package test asserting Foundation path behaviour can pass on
  Linux and fail on macOS (or vice versa).** `URL(fileURLWithPath:)` resolves
  Windows-shaped paths differently per platform. If a fixture is inherently
  platform-shaped, say so in a comment; don't encode one platform's parse as
  the expectation for a suite that runs everywhere.
- **Adding an Apple-only import to a file under `Packages/TailscreenKit/Sources/`
  breaks `linux-protocol`.** Reproduce with `make test-protocol` (runs on
  macOS too) before concluding a CI failure there is flaky.
- **A decision with two silent failure directions needs both asserted, plus
  an inequality between the two runs** — asserting only "the safe case holds"
  passes against an implementation that never does the risky thing either
  (e.g. congestion-control "missing feedback suppresses the up-ramp": the test
  that matters is the inequality against a run with the same inputs but fresh
  feedback).

## Finding existing suites

Don't re-derive the catalog by reading this file — it's stale the moment
someone adds a suite. Instead:

```bash
# Portable decision/util/wire suites (~60+, growing):
ls Packages/TailscreenKit/Tests/TailscreenProtocolTests/
ls Packages/TailscreenKit/Tests/TailscreenSharerTests/
ls Packages/TailscreenKit/Tests/TailscreenViewerTests/

# Everything mac-only:
ls Apps/macOS/Tests/TailscreenTests/

# Other package test dirs:
find Packages -type d -name Tests

# Find the suite (if any) covering a type or seam by name:
rg -l 'ForTesting' Packages/TailscreenKit/Sources
rg -rn '<TypeName>' --glob '*Tests.swift'
```

A representative example per area, if you want one to model a new suite on
rather than reading the whole directory: `AdaptiveBitrateTests` (extract-the-
decision, sharer tier), `ViewerSessionLifecycleTests` (portable UI-model state
machine), `WireByteRegistryTests` (registry pattern), `RTPBufferPoolTests`
(concurrency case), `VoicePathTests` (explicit-clock, fake-driven end-to-end
within one process), `LocalizationCatalogTests` (cross-tree string scan).
