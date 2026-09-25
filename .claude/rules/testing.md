---
paths:
  - "**/Tests/**"
  - "**/*Tests.swift"
  - "scripts/**"
  - "e2e/**"
  - "test-local.sh"
---

# Testing

The catalog of extracted pure-decision suites, test-only seams, and which package a new suite belongs in is the **`test-catalog` skill** — invoke it when adding or moving a test. This file covers running tests and the local-only harnesses.

## Unit tests

```bash
make test
# or: export PKG_CONFIG_PATH="$(pwd)/Packages/TailscaleKit"
#     cd Apps/macOS && swift test
```

## ThreadSanitizer (`linux-tsan`, and `test-tsan` on macOS)

```bash
make tailscale   # once per checkout — not optional
PKG_CONFIG_PATH="$PWD/Packages/TailscaleKit" \
  swift test --package-path Packages/TailscreenKit --sanitize=thread
```

`TailscreenSharerTests` links `TailscreenSharer` → `TailscaleKit`, so `libtailscale.a` is a link-time input even though nothing here calls tsnet — skip `make tailscale` and you get `undefined reference to 'tailscale_close'`, which reads like a broken toolchain rather than a missing step.

This is the `linux-tsan` job verbatim. Unlike macOS's `test-tsan` (runs the app target, trips over third-party C noise from libtailscale's Go runtime / ScreenCaptureKit's XPC, hence `continue-on-error`), this package imports no Apple framework and calls no tsnet — **a warning here is a real race**.

### Lock with `Guarded`, never `Synchronization.Mutex`

TSan learns happens-before from the pthread primitives it interposes on; `Mutex` bypasses those and parks on the futex directly, so it never sees the release/acquire pair and reports a **"Swift access race" inside the lock body** — on correct code. Worse: **a `Mutex`-guarded type is invisible to the gate**, not failing but simply unchecked, so a green `linux-tsan` says nothing about it. No type in this repo uses `Mutex` any more — `TailscreenProtocol.Guarded` (`Mutex`'s `withLock { $0 … }` shape over an `NSLock`) replaced every one; full argument in `Guarded.swift`. (`TailscreenL10n` keeps a private copy — that package has no dependencies on purpose.)

A bare `NSLock` beside the state is still fine and common (`FrameStore`, `VoiceDownlink`, `DiagnosticsRecorder`, ~30 others) — it's what the sanitizer needs; `Guarded` is the default for *new* lock-guarded state and additionally makes the state unreachable without the lock. Reach for bare `NSLock` when the locking isn't one scoped body (`DiagnosticsRecorder.record` releases early; `DiagnosticsBundle` guards two separate statics).

Reproduce in 30s, no repo code, `swift build --sanitize=thread`:

```swift
struct State { var counter: UInt64 = 0; var items: [UInt64] = [] }
let lock = Mutex<State>(State())
DispatchQueue.concurrentPerform(iterations: 8) { _ in
    for _ in 0..<250 { lock.withLock { $0.counter &+= 1; $0.items.append($0.counter) } }
}
```

Reports the race; the same hammer over `NSLock`/`Guarded` is clean and still catches a genuine unsynchronized race. Checked on Swift 6.3 (CI) and a 6.5 snapshot two majors ahead — identical result, so don't wait on a toolchain fix.

### A lock nothing exercises concurrently proves nothing

TSan only reports races it watches execute. A new genuinely multi-threaded type needs a test that hammers it from several threads and asserts interleaving-independent invariants (see `RTPBufferPoolTests`, `RetransmitBufferTests`), or the gate has nothing to watch.

## E2E connectivity (real tsnet transport)

1. **Local headscale (preferred):**
   ```bash
   make test-e2e         # one-shot
   # or: eval "$(make e2e-up)"; swift test --filter TailscaleConnectivityTests; make e2e-down
   ```
   `scripts/e2e-up.sh` boots `e2e/docker-compose.yml`, creates a user, mints a reusable pre-auth key.
2. **Real tailnet:** export your own `TAILSCREEN_TS_AUTHKEY` and run `swift test`.
3. **Docker-free:** `scripts/e2e-up-native.sh` downloads the pinned headscale binary (keep `HEADSCALE_VERSION` matching `e2e/docker-compose.yml`), runs it natively; tear down with `scripts/e2e-down-native.sh`.

**These tsnet suites can't run on CI** — GitHub's hosted macOS sandbox blocks the userspace-WireGuard handshake / DERP-STUN, and `node.up()` has no internal timeout, so it just hangs. Anything bringing up a tsnet node (`TailscaleConnectivityTests`, screen-share E2E suites) is local-only; only pure-logic suites (`AdaptiveBitrateTests`, `VideoCodecTests`, `VoiceChannelTests`, `RTPPacketTests`, `RTPLossyChannelTests`, etc.) run on CI.

`RTPLossyChannelTests` is the CI-able stand-in for network impairment: real packetize → `LossyChannel` (deterministic seeded loss/reorder/duplication) → depacketize, asserting recovery; also closes the NACK loop (packetize → seeded loss → `NACKScheduler` + depacketizer → retransmit) and the FEC leg (`runRecoveryLoop`: server-side parity groups, viewer-side FEC scheduler + `FECGroupBuffer`). `LossyChannel` (`Apps/macOS/Tests/`) is reusable by any in-process packet test but can't impair the live tsnet path — for that see `scripts/net-impair.sh` below.

Connectivity tests skip/fail without an auth key — expected.

**Browser ↔ sharer, no internet** (`make test-web-spike`, Linux; CI's `linux-web-spike`): `web/viewer/e2e/spike.mjs` boots `web/viewer/cmd/localderp` (DERP+STUN+`/derpmap` stand-in, self-signed TLS), Xvfb with a gradient, `tailscreen-sharer-linux --link --link-relay-map-url … --approve-guests` (link-only, no tsnet/headscale), and headless Chromium (Playwright, `--no-proxy-server` so a container's `HTTPS_PROXY` doesn't capture loopback `wss://`). Asserts the page reaches `acked` (HELLO → parked → auto-approved → HELLO_ACK), ≥50 video datagrams, and where the browser decodes H.264, ≥10 decoded frames + non-flat canvas. Prefers **Google Chrome** (`playwright install chrome`; `PW_CHANNEL` overrides) — Playwright's own Chromium has no H.264 decoder (WebCodecs reports every config unsupported); `PW_BROWSER=firefox` also decodes. Also drives remote control end to end (`--allow-control --grant-control`; pointer moves become XTEST, read back via `xdotool getmouselocation`, skipped with a NOTE if absent) and asserts drawing tools stay hidden (headless sharer advertises no `annotations` capability). `web/viewer/e2e/wire.test.mjs` checks the pure wire half with no browser first. Knobs: `TAILSCREEN_SHARER_BIN`, `TAILSCREEN_E2E_DISPLAY` (default `:99`), `TAILSCREEN_E2E_FPS`, `TAILSCREEN_E2E_MIN_VIDEO`, `TAILSCREEN_E2E_MIN_FRAMES`, `PW_CHANNEL`, `PW_BROWSER`. Needs Node with global `playwright` (`NODE_PATH=$(npm root -g)`, set by the Makefile) + its Chromium. `--approve-guests`/`--grant-control` are the guest-side twins of `TAILSCREEN_OPEN_DOOR` — never for a share with a person in front of it.

## Local screen-share E2E (LOCAL ONLY)

GitHub's macOS runners can't grant Screen Recording TCC or host a real display, so these run only locally. Most run over local-headscale tsnet with `filterData: nil` (no capture-helper) and need no Screen Recording permission.

1. **`ScreenShareSyntheticFramesTests`** — server (no helper) + real client over local-headscale tsnet, pre-encoded AVCC injected directly. CI-eligible (skips if VideoToolbox produces no output).
2. **`ScreenShareCaptureHelperTests`** — full pipeline incl. real `--capture-helper` against the main display, real on-screen `NSWindow` so Metal renders. Jiggles the cursor (a static screen starves the encoder). Local-only, self-skips on `CI`/`GITHUB_ACTIONS`. First run pops the Screen Recording prompt.
3. **`ScreenShareFanoutTests`** — two viewers on one server: video fan-out + audio relay (RTP reaches sharer and is relayed to the other viewer via server-assigned SSRC); a second test covers system audio (`OpusVoiceEncoder`, PT 99) reaching both.
4. **`ScreenShareControlChannelTests`** — annotation op over TCP back-channel reaches `server.onAnnotationReceived`; a viewer PLI is recorded via the test-only seam.
5. **`ScreenShareRequestToShareTests`** — two raw tsnet nodes: request-to-share round trip incl. accept/decline/no-answer.
6. **`ScreenShareAccessControlTests`** — headless server + `requireApproval`: park/approve, policy-driven auto-admit/deny, sharer's one-time kick (re-admits on reconnect since nothing was remembered, unlike "Deny & Block").
7. **`ScreenShareRemoteControlTests`** — opt-in remote-control grant flow: request/grant/gate/revoke, plus the "Allow control requests" toggle off path. Skipped without `TAILSCREEN_TS_AUTHKEY`.
8. **`PickerHelperSmokeTests`** — `--picker-helper` `TAILSCREEN_AUTOSHARE_DISPLAY=1` short-circuit (always runs). Full picker-UI lifecycle + SIGTERM test is opt-in: `TAILSCREEN_RUN_PICKER_LIFECYCLE_TEST=1`.

```bash
make test-e2e-local     # XCTest suites above, under local headscale
make test-e2e-harness   # two real Tailscreen processes, asserted by log marker
```

The harness greps the merged log for `E2E_MARKER firstFrame width=… height=…` from `AppState`'s viewer-side `onVideoSizeChanged`.

**Linux sharer → Linux viewer** (`scripts/e2e-linux-sharer.sh`, local-only): local headscale + Xvfb with real content, `tailscreen-sharer-linux` (X11 `CaptureEncoding`) + `tailscreen-viewer-probe` (counting sink instead of a window); asserts admission, decoded frames at display geometry, and non-uniform pixels (real capture, not a flat rectangle). Also pins that with no injector supplied, advertised `serverCaps` omits `.remoteControl`.

## Env-var test affordances

| Env var | Read by | Effect |
|---------|---------|--------|
| `TAILSCREEN_OPEN_DOOR=1` | Main process (`ViewerApprovalPreference.load`) | Force require-approval off regardless of stored preference. Never in production. |
| `TAILSCREEN_AUTOSHARE_DISPLAY=1` | `--picker-helper` subprocess | Skip interactive picker; emit a synthetic main-display selection and exit. |
| `TAILSCREEN_FORCE_STREAM=1` | Portable viewer (`ViewerConfig.useStreamTransport`) | Run the session over the stream profile (spec §2.2): datagram plane rides framed TCP as `.mediaDatagram`, caps drop NACK/FEC. Exercises the UDP-blocked fallback (HELLO times out against a pre-profile sharer). |
| `TAILSCREEN_AUTOSTART_SHARE=1` | Main process (`AppState.init`) | Once signed in, auto-invoke `presentNativePicker()`. Pair with `TAILSCREEN_AUTOSHARE_DISPLAY=1`. |
| `TAILSCREEN_AUTOCONNECT_TO=<prefix>` | Main process (`AppState.init`) | Once signed in, connect to the first discovered peer whose hostname or displayed name starts with `<prefix>`. |
| `TAILSCREEN_AUTOSHARE_LINK=1` | Main process (`AppState.startSharing`) | Mint the share link at share start, print `E2E_MARKER shareLink token=…` for a scripted second instance to join. |
| `TAILSCREEN_HELPER_EXE=<path>` | `HelperScreenCapture` / `PickerHelperClient` | Override `Bundle.main.executableURL` for helper spawns (needed under xctest). |
| `TAILSCREEN_SOAK=1` | `SoakTests` | Opt in to the nightly soak tier (ParserFuzz ~50× budget + seeded LossyChannel matrix). Off for `make test`/PR CI. |
| `TAILSCREEN_RUN_PICKER_LIFECYCLE_TEST=1` | `PickerHelperSmokeTests` | Opt in to the on-screen picker lifecycle test. |
| `TAILSCREEN_DEBUG_INPUT=1` | Viewer + sharer + mac injector | Instrument remote-control input timing (per-write duration, admission gap, scroll delta incl. banked sub-line accumulation). Diagnostic only. |
| `TAILSCREEN_DEBUG_FEC=1` | Server + viewer | Log the FEC-arming feedback loop (RTT, loss, arm decision every 5s; receiver-report sends). Diagnoses why FEC didn't gate under real loss (e.g. RTT staying 0 means RRs aren't landing). Diagnostic only. |

## Local manual testing — multiple instances on one Mac

```bash
./test-local.sh           # 2 instances (default)
./test-local.sh 3         # N instances
```

Each child gets `TAILSCREEN_INSTANCE=<i>`, suffixing the Tailscale state dir and hostname (`wisp-1`, `wisp-2`). Without it, two processes share one state dir, reuse one machine key, and the peer list shows zero peers (each sees only itself).

Merged output: `/tmp/tailscreen-merged.log` (override `TAILSCREEN_LOG`). Ctrl-C kills the process group.

| Env var | Effect |
|---------|--------|
| `TAILSCREEN_DEBUG_ZOMBIES=1` | `NSZombieEnabled` + malloc stack logging — over-releases log instead of crashing |
| `TAILSCREEN_DEBUG_ASAN=1` | Sets `ASAN_OPTIONS`; also rebuild with `swift build -Xswiftc -sanitize=address` |
| `TAILSCREEN_DEBUG_GMALLOC=1` | libgmalloc — known to break ScreenCaptureKit's XPC; prefer Instruments' Zombies template |

## Simulating a bad network on one Mac — `scripts/net-impair.sh`

Loopback/local-headscale deliver ~0% loss, in order — hides loss-driven PLI/keyframe storms, the adaptive-bitrate sweep, stall+recovery, and head-of-line blocking. Uses pf + dummynet to beat up node-to-node UDP:

```bash
sudo ./scripts/net-impair.sh up --loss 3 --delay 80   # 3% loss, 80 ms each way
./test-local.sh 2                                      # share + view, watch it cope
sudo ./scripts/net-impair.sh down                      # always tear down
sudo ./scripts/net-impair.sh status                    # inspect active pipes/anchor
```

Knobs: `--loss PCT`, `--delay MS`, `--bw RATE` (e.g. `5Mbit/s`), `--reorder PCT` (+`--reorder-delay MS`), `--iface IFACE` (default `lo0`). Leaves headscale control (8080/tcp) and STUN (3478/udp) alone.

Caveats: best-effort — a DERP-relayed fallback path may not be on `lo0` (confirm via rising PLI / dropping bitrate in the stats overlay, or try `--iface en0`); dummynet has no native reorder knob (`--reorder` uses a two-pipe probability workaround, may be rejected on some pf versions). For deterministic, root-free, CI-able coverage instead, use `RTPPacketTests` and `RTPLossyChannelTests` (via `LossyChannel`) — this harness is the end-to-end complement, not a replacement.
