---
paths:
  - "**/Tests/**"
  - "**/*Tests.swift"
  - "scripts/**"
  - "e2e/**"
  - "test-local.sh"
---

# Testing

The catalog of extracted pure-decision suites, the test-only seams, and the which-package-does-a-suite-live-in rule are in the **`test-catalog` skill** — invoke it when adding or moving a test. This file covers running tests and the local-only harnesses.

## Unit tests

```bash
make test
# or: export PKG_CONFIG_PATH="$(pwd)/Packages/TailscaleKit"
#     cd Apps/macOS && swift test
```

## E2E connectivity (real tsnet transport)

Two paths:

1. **Local headscale (preferred for CI/dev):**
   ```bash
   make test-e2e         # one-shot
   # or, manually:
   eval "$(make e2e-up)" # exports TAILSCREEN_TS_AUTHKEY + TAILSCREEN_TS_CONTROL_URL
   swift test --filter TailscaleConnectivityTests
   make e2e-down
   ```
   `scripts/e2e-up.sh` boots `e2e/docker-compose.yml` (headscale on `localhost:8080`), creates a user, and mints a reusable ephemeral pre-auth key.

2. **Real tailnet:** export your own `TAILSCREEN_TS_AUTHKEY` from the Tailscale admin console and run `swift test`.

3. **Docker-free headscale (local, no Docker):** `scripts/e2e-up-native.sh` downloads the pinned headscale release binary (keep `HEADSCALE_VERSION` in lockstep with `e2e/docker-compose.yml`), runs it natively, and emits the same env exports; tear down with `scripts/e2e-down-native.sh`. Useful on machines without Docker.

**These tsnet suites can't run on CI.** Tried on `macos-latest` via the native script: headscale came up healthy, but the first tsnet `node.up()` hung — GitHub's hosted macOS runner sandbox doesn't let the userspace-WireGuard handshake / DERP-STUN (`:3478/udp`) complete, and `node.up()` has no internal timeout. So anything that brings up a tsnet node (`TailscaleConnectivityTests` and all the screen-share E2E suites) is local-only. Only the pure-logic suites (`AdaptiveBitrateTests`, `VideoCodecTests`, `VoiceChannelTests`, `RTPPacketTests`, `RTPLossyChannelTests`, etc.) run on CI.

`RTPLossyChannelTests` is the CI-able stand-in for the impairment harness: it runs the real packetize → `LossyChannel` (deterministic, seeded loss/reorder/duplication) → depacketize pipeline and asserts recovery (reordering/duplication never drop or tear frames; genuine loss is signaled and the pipeline never wedges). It also closes the **NACK-recovery loop** (packetize → seeded loss → `NACKScheduler` + depacketizer → retransmit re-injection): loss recovered by NACK with zero PLIs and no torn frames, PLI fallback when retransmits also drop (never wedges), and small reordering producing neither NACK nor PLI. Its **FEC leg** (`runRecoveryLoop`: server-side `groupRanges` + `parityBody` per frame, viewer-side FEC-mode scheduler + `FECGroupBuffer` in front of the depacketizer) pins the layered handoff: seeded ≤1-loss-per-group recovered with zero NACKs/PLIs (H.264 + HEVC), ~10 % loss handing multi-loss groups to NACK with no torn frames, dropping every parity datagram reproducing today's NACK behavior exactly, and a late original after its FEC recovery changing nothing. `LossyChannel` (in `Apps/macOS/Tests/`) is reusable by any in-process packet test. It can't impair the live tsnet path — for that, see `scripts/net-impair.sh` (local-only).

Connectivity tests skip or fail without an auth key — that's expected.

**Browser ↔ sharer, no internet** (`make test-web-spike`, Linux; CI's `linux-web-spike`): the browser viewer's transport spike (`plans/browser-viewer.md`, Phase 2). `web/viewer/e2e/spike.mjs` boots `web/viewer/cmd/localderp` (a DERP+STUN+`/derpmap` stand-in for the relay fleet, self-signed TLS with `InsecureForTests`), an Xvfb display with a gradient on it, `tailscreen-sharer-linux --link --link-relay-map-url … --approve-guests` (a link-only share: no tsnet, no headscale), and headless Chromium (Playwright, `ignoreHTTPSErrors` for the relay's cert, `--no-proxy-server` so a container's `HTTPS_PROXY` never captures the loopback `wss://`). It asserts the page reaches `acked` — HELLO as a `mediaDatagram` frame, parked, auto-approved, `HELLO_ACK` — then ≥ 50 video datagrams over the stream, then (where the browser decodes H.264) ≥ 10 decoded frames and a non-flat canvas (sampled luma spread), and prints the wasm sizes. It prefers **Google Chrome** (`playwright install chrome`; `PW_CHANNEL` overrides): Playwright's own Chromium ships without H.264, so there only the transport half runs. Knobs: `TAILSCREEN_SHARER_BIN`, `TAILSCREEN_E2E_DISPLAY` (default `:99`), `TAILSCREEN_E2E_FPS`, `TAILSCREEN_E2E_MIN_VIDEO`. Needs Node with the global `playwright` module (`NODE_PATH=$(npm root -g)`, which the Makefile sets) and its Chromium. `--approve-guests` is the guest-side twin of `TAILSCREEN_OPEN_DOOR` — never for a share with a person in front of it.

## Local screen-share E2E (LOCAL ONLY)

These test surfaces exercise the screen-share pipeline beyond what GitHub Actions can run — its macOS runners can't grant Screen Recording TCC, can't host a real display, and `replayd`/`SCStream` won't come up. Most run over local-headscale tsnet with the server in `filterData: nil` mode (no capture-helper), so they're headless and need no Screen Recording permission.

1. **`ScreenShareSyntheticFramesTests`** — server (no helper) + real client over local-headscale tsnet, pre-encoded AVCC injected into the broadcast path. Asserts on `client.onDecodedFrameForTesting` (decode signal — the renderer's display-link render path needs an on-screen view, which xctest lacks). CI-eligible (skips if VideoToolbox produces no output, e.g. virtualized runners).
2. **`ScreenShareCaptureHelperTests`** — full pipeline including the real `--capture-helper` subprocess against the main display, hosted in a real on-screen `NSWindow` so the Metal **render** path runs and `renderer.onVideoSizeChanged` fires. Jiggles the cursor to keep ScreenCaptureKit delivering frames (a static screen starves the encoder). Local-only — self-skips on `CI` / `GITHUB_ACTIONS`. First run pops macOS's Screen Recording permission prompt on `Apps/macOS/.build/debug/Tailscreen`; subsequent runs are unattended.
3. **`ScreenShareFanoutTests`** — two viewers on one server: asserts video fan-out (both decode one broadcast) and audio relay (one viewer's RTP reaches the sharer locally **and** is relayed to the other viewer, gated by the server-assigned SSRC). A second test (`testSystemAudioReachesBothViewers`) injects a real `OpusVoiceEncoder` AU via `broadcastSystemAudioForTesting` and asserts both viewers receive it tagged PT 99.
4. **`ScreenShareControlChannelTests`** — viewer→sharer control paths: annotation op over the TCP back-channel reaches `server.onAnnotationReceived`; a viewer PLI is recorded (observed via the test-only `onPLIRecordedForTesting` seam, since no helper is attached to act on the keyframe request).
5. **`ScreenShareRequestToShareTests`** — two raw tsnet nodes: one sends `TailscreenMetadataService.sendRequestToShareAwaitingResponse`, the other's `TailscreenControlListener.onRequestToShare` fires (now with the connection UUID). Also covers the accept/decline round-trip: a `.shareResponse` sent back on the same connection resolves the requester's await to `.accepted`/`.declined`, and silence resolves to `.noAnswer`. No UI/notifications.
6. **`ScreenShareAccessControlTests`** — headless server (`filterData: nil`, `requireApproval` on) + three sequential viewers over local-headscale tsnet: an unknown viewer parks pending and `approveViewer` admits it; pushing an `.allow` policy via `setAccessPolicies` auto-admits a parked viewer once its StableNodeID resolves; pushing `.deny` rejects it (viewer's `onDeniedBySharer` fires via HELLO_DENY) and it never enters the fan-out roster. A second test covers the sharer's one-time kick (`server.disconnectViewer`, the SharingCard viewer-row ✕): an admitted viewer is expelled (its `onDeniedBySharer` fires, roster empties) and the *same node identity* (reused state dir) reconnects to park pending again and gets re-admitted — proving nothing was remembered, unlike "Deny & Block".
7. **`ScreenShareRemoteControlTests`** — headless server (`filterData: nil`) + one admitted viewer over local-headscale tsnet, exercising the opt-in remote-control grant flow: `requestControl` → server `onControlRequestsChanged` surfaces the request; input sent before a grant is dropped by the server gate; `grantControl` (Accessibility check bypassed via `grantBypassesAccessibilityForTesting`) → viewer `onControlGranted` fires; input after the grant passes the gate (`onInputEventForTesting`, no real `CGEventPost`); the viewer's `releaseControl()` clears the server grant (`onControlGrantChanged` → nil) and the viewer gets `onControlRevoked`. A second test covers the "Allow control requests" toggle off: `setAllowControlRequests(false)` → an admitted viewer's request is declined immediately with `.controlRevoked` and never surfaces to `onControlRequestsChanged`. Skipped without `TAILSCREEN_TS_AUTHKEY`.
8. **`PickerHelperSmokeTests`** — verifies the `--picker-helper` `TAILSCREEN_AUTOSHARE_DISPLAY=1` short-circuit (no UI; always runs locally). A second test exercises the full picker-UI lifecycle and SIGTERM path — that one pops the real picker on screen for ~2 s and is **opt-in**: set `TAILSCREEN_RUN_PICKER_LIFECYCLE_TEST=1` to enable.

```bash
make test-e2e-local     # XCTest suites above, under local headscale
make test-e2e-harness   # two real Tailscreen processes, asserted by log marker
```

The harness greps the merged log for `E2E_MARKER firstFrame width=… height=…`, emitted from `AppState`'s viewer-side `onVideoSizeChanged` callback on the first decoded frame.

**Linux sharer → Linux viewer** (`scripts/e2e-linux-sharer.sh`, local-only): the non-macOS counterpart. Brings up local headscale + an Xvfb display with real content, runs `tailscreen-sharer-linux` (the portable `TailscaleScreenShareServer` + the X11 `CaptureEncoding` backend) and `tailscreen-viewer-probe` (the real receive path with a counting sink instead of a window), and asserts the viewer was admitted, decoded frames at the display's geometry, and that those frames are **non-uniform** — i.e. real captured pixels rather than a flat rectangle that a frame-count assertion alone would accept. It also incidentally pins the conditional-capability behaviour: with no injector supplied the advertised `serverCaps` omits `.remoteControl`.

## Env-var test affordances

| Env var | Read by | Effect |
|---------|---------|--------|
| `TAILSCREEN_OPEN_DOOR=1` | Main process (`ViewerApprovalPreference.load`) | Force the require-approval gate off regardless of the stored preference. Viewer approval defaults **on**, so the scripted harness and `test-local.sh` set this to keep automated viewers from parking on the approval prompt. Never set in production. |
| `TAILSCREEN_AUTOSHARE_DISPLAY=1` | `--picker-helper` subprocess | Skip the interactive picker; emit a synthetic main-display `PickerSelection` and exit. |
| `TAILSCREEN_FORCE_STREAM=1` | Portable viewer (`ViewerConfig.useStreamTransport` default) | Run the session over the stream profile (spec §2.2): the whole datagram plane rides the framed TCP back-channel as `.mediaDatagram` frames instead of UDP, and the advertised caps drop NACK/FEC. The way to exercise the UDP-blocked fallback end to end; against a pre-profile sharer the HELLO times out, which is the profile's designed degradation. |
| `TAILSCREEN_AUTOSTART_SHARE=1` | Main process (`AppState.init`) | Once signed in, automatically invoke `presentNativePicker()`. Pair with `TAILSCREEN_AUTOSHARE_DISPLAY=1`. |
| `TAILSCREEN_AUTOCONNECT_TO=<prefix>` | Main process (`AppState.init`) | Once signed in, discover peers and connect to the first one whose hostname starts with `<prefix>` — matched against both the raw hostname (`tailscreen-wisp`, what the harnesses pass) and the displayed name (`wisp`, what the peer list shows). |
| `TAILSCREEN_AUTOSHARE_LINK=1` | Main process (`AppState.startSharing`) | Mint the share link the moment a share starts (a guest-only share already has its token; a tailnet share enables the link as the toggle would) and print `E2E_MARKER shareLink token=…` so a scripted second instance can join by token. The seed for a future `test-local.sh --guest` mode. |
| `TAILSCREEN_HELPER_EXE=<path>` | `HelperScreenCapture` / `PickerHelperClient` | Override `Bundle.main.executableURL` for helper spawns. Only used by XCTests (under xctest, `Bundle.main` points at the test harness, not Tailscreen). |
| `TAILSCREEN_SOAK=1` | `SoakTests` | Opt in to the nightly long-run soak tier (ParserFuzz at ~50× budget + the seeded LossyChannel impairment matrix). Off for `make test` and PR CI; `.github/workflows/soak.yml` sets it. |
| `TAILSCREEN_RUN_PICKER_LIFECYCLE_TEST=1` | `PickerHelperSmokeTests` | Opt in to the picker-UI lifecycle test that pops the real picker on screen for ~2 s before SIGTERM. Skipped by default to keep `make test-e2e-local` non-interactive. |
| `TAILSCREEN_DEBUG_INPUT=1` | Viewer (`TailscaleScreenShareClient`) + sharer (`TailscaleScreenShareServer`, `RemoteControlInjector`) | Instrument the remote-control input path: the viewer logs how long each framed `.inputEvent` write actually took (plus a 1 Hz `n=/mean=/max=` summary), the sharer logs the gap between admitted events, and the mac injector logs each scroll's wire delta and the whole-line count it became — **including when the sub-line accumulator banked it and injected nothing**, which is the one thing that looks identical to no scroll arriving at all. Both ends measure the same stall independently, so a viewer reporting multi-second sends with a sharer reporting matching arrival gaps localizes it to the send path rather than the network. Off by default; diagnostic only. |
| `TAILSCREEN_DEBUG_FEC=1` | Server (`TailscaleScreenShareServer`) + viewer (`TailscaleScreenShareClient`) | Log the FEC-arming feedback loop: the server prints per-viewer FEC sweep inputs (measured RTT, residual/raw loss, recovered/expected, `.fec` cap) and the arm decision every 5 s; the viewer prints each receiver-report send (fracLost, whether a PING was echoed, delay). Diagnoses why FEC did/didn't gate on under real loss (e.g. RTT staying 0 ⇒ RRs/ping echoes aren't landing so the >150 ms gate can't trip). Off by default; diagnostic only. |

## Local manual testing — multiple instances on one Mac

```bash
./test-local.sh           # 2 instances (default)
./test-local.sh 3         # N instances
```

Each child gets `TAILSCREEN_INSTANCE=<i>`, which suffixes the Tailscale state directory and hostname (e.g. `wisp-1`, `wisp-2`). Without it, two processes share `~/Library/Application Support/Tailscreen/tailscale`, reuse the same machine key, and the browser sees zero peers (it's looking at its own node).

Merged stdout/stderr lands in `/tmp/tailscreen-merged.log` (override with `TAILSCREEN_LOG`). Ctrl-C kills the whole process group.

Memory-debug modes (set before invoking the script):

| Env var | Effect |
|---------|--------|
| `TAILSCREEN_DEBUG_ZOMBIES=1` | `NSZombieEnabled` + malloc stack logging — over-releases log instead of crashing |
| `TAILSCREEN_DEBUG_ASAN=1` | Sets `ASAN_OPTIONS`; **also rebuild with** `swift build -Xswiftc -sanitize=address` |
| `TAILSCREEN_DEBUG_GMALLOC=1` | libgmalloc — known to break ScreenCaptureKit's XPC; prefer Instruments' Zombies template |

## Simulating a bad network on one Mac — `scripts/net-impair.sh`

Loopback and local-headscale deliver packets with ~0% loss, in order, at a 16 KB MTU. That hides every WAN-only failure mode: loss-driven PLI/keyframe storms, the adaptive-bitrate sweep, viewer stall + recovery, and one-slow-viewer head-of-line blocking. `scripts/net-impair.sh` uses pf + dummynet (the machinery behind Network Link Conditioner) to beat up the node-to-node UDP transport so those paths actually run.

```bash
sudo ./scripts/net-impair.sh up --loss 3 --delay 80   # 3% loss, 80 ms each way
./test-local.sh 2                                      # share + view, watch it cope
sudo ./scripts/net-impair.sh down                      # always tear down when done
sudo ./scripts/net-impair.sh status                    # inspect active pipes/anchor
```

Knobs: `--loss PCT`, `--delay MS`, `--bw RATE` (e.g. `5Mbit/s`), `--reorder PCT` (+`--reorder-delay MS`), `--iface IFACE` (default `lo0` — two co-located tsnet nodes prefer their loopback endpoints). It impairs UDP on the interface while leaving headscale control (8080/tcp) and STUN (3478/udp) alone so setup still works.

Caveats: it's **best-effort** — if the two nodes fall back to a DERP-relayed path the flow may not be on `lo0` (confirm impairment is biting via the viewer's rising PLI count / dropping bitrate in the stats overlay; otherwise try `--iface en0`). dummynet has no native packet-reorder knob, so `--reorder` uses the two-pipe + `probability` workaround and may be rejected on some macOS pf versions. For **deterministic, root-free, CI-able** reorder/loss/duplicate coverage of the depacketizer, use the unit tests in `RTPPacketTests` and the end-to-end pipeline tests in `RTPLossyChannelTests` (via `LossyChannel`) instead — the harness is the end-to-end complement, not a replacement.
