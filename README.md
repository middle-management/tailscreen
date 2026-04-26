<p align="center">
  <img src="docs/assets/logo.svg" alt="Tailscreen logo" width="180">
</p>

# Tailscreen

[![Build Status](https://github.com/middle-management/tailscreen/actions/workflows/build.yml/badge.svg)](https://github.com/middle-management/tailscreen/actions/workflows/build.yml)

📖 **Documentation:** <https://tailscreen.dev>

Lightweight screen sharing between Macs, for the times when spinning up a full conferencing app feels like overkill.

Tailscreen is a tiny macOS menubar app that streams one Mac's screen to another Mac over [Tailscale](https://tailscale.com/). It uses ScreenCaptureKit to grab pixels, VideoToolbox to encode HEVC (with H.264 as a fallback for older hardware), and Tailscale's WireGuard tunnel to move bytes. There is no server, no port to forward, and no account to create beyond Tailscale itself.

You hit "Start Sharing", the other person hits "Browse Shares", they click your machine, a window opens. That's the whole thing.

## What you get

- 60 fps full-Retina hardware-encoded HEVC (or H.264 on Macs whose VideoToolbox can't do HEVC) over the same WireGuard tunnel that Tailscale already gives you. Direct peer-to-peer when the network allows; Tailscale's DERP relays when it doesn't.
- Automatic peer discovery — Tailscreen probes your tailnet and lists which machines are sharing. No IP-typing.
- Ephemeral tsnet nodes. Each session spins up a fresh node and Tailscale tears it down when you're done; your admin console doesn't fill up with ghosts.
- Two-way annotations over a reliable TCP back-channel, so strokes don't get dropped when video does.
- A menubar icon. That's the entire UI footprint.

## What you need

- macOS 15 (Sequoia) or later. Earlier macOS versions, iOS, and Linux aren't supported.
- Swift 6 toolchain if you're building from source. Otherwise just grab a release.
- A Tailscale account. The free personal tier is fine.
- Screen Recording permission. macOS will ask the first time.

## Install

### From a release

Grab the latest `Tailscreen-<version>-macOS.zip` from [Releases](https://github.com/middle-management/tailscreen/releases), unzip, drag to `/Applications`. The release zip is a universal binary, signed and notarized when the build secrets are configured.

### From source

The project is Swift Package Manager only. There's no Xcode project. Builds go through the top-level `Makefile` because that's where `PKG_CONFIG_PATH` gets set so SwiftPM can find the C library.

You'll need:

- **Swift 6** toolchain (Xcode 16+, or [swift.org](https://swift.org/download/)).
- **Go 1.21+** at build time, to compile `libtailscale.a`. Not needed at runtime.

Then:

```bash
git clone --recurse-submodules https://github.com/middle-management/tailscreen.git
cd tailscreen
make build
```

If you forget `--recurse-submodules`, the build will fail with a confusing missing-headers error. Fix:

```bash
git submodule update --init --recursive
```

The single most common build failure is running bare `swift build` first — it'll fail to link, because `libtailscale.a` doesn't exist yet. Always go through `make`.

For a release build:

```bash
make release      # → .build/release/Tailscreen
make install      # → ~/bin/Tailscreen
```

More detail in the [Install docs](https://tailscreen.dev/install/).

## Run it

```bash
swift run                       # or: make run
.build/release/Tailscreen       # after `make release`
```

## Use it

### Sharing

1. Click the 📺 in the menubar.
2. **Start Sharing**.
3. Approve Screen Recording when macOS prompts you, then quit and relaunch — macOS doesn't push the new permission to a running process.
4. **Show Tailscale Info** prints the hostname and 100.x.x.x to share with whoever's connecting.

### Viewing

The good way:

1. Click the 📺.
2. **Browse Shares...**.
3. Tailscreen probes your tailnet and lists shares. Click **Connect**.

The other way: **Connect to...** and type a Tailscale hostname (`macbook-pro`) or IP (`100.x.x.x`).

### Stopping

**Stop Sharing** on the sharer side; **Disconnect** or close the window on the viewer. Ephemeral tsnet nodes get torn down automatically — nothing to clean up in the Tailscale admin console.

## Testing on one Mac

You can exercise the full peer-discovery path on a single machine:

```bash
./test-local.sh        # 2 instances
./test-local.sh 3      # N instances
```

Each child gets `TAILSCREEN_INSTANCE=<i>`, which suffixes the Tailscale state directory and hostname. **This step matters.** If two processes share the state dir at `~/Library/Application Support/Tailscreen/tailscale`, they reuse the same machine key, the tailnet treats them as the same device, and **Browse Shares** comes back empty. It's by far the most common cause of an empty peer list when testing locally.

This setup tests Tailscale integration and peer discovery. It does **not** test NAT traversal — both processes share the same network stack. For that, use two actual machines.

## Architecture, briefly

```
TailscreenApp (@main)
  └─ AppState (@MainActor)
       ├─ TailscaleScreenShareServer
       │    └─ ScreenCapture → VideoEncoder → RTPPacket → UDP/7447
       │       + TCP/7447 (annotations + metadata)
       ├─ TailscaleScreenShareClient
       │    └─ UDP/7447 → RTP depacketize → VideoDecoder → MetalViewerRenderer
       │       + TCP/7447 (annotations out)
       ├─ TailscalePeerDiscovery   ── LocalAPI + TCP probe
       ├─ TailscaleIPNWatcher      ── IPN bus subscription
       ├─ TailscaleAuth            ── browser-based login
       └─ TailscreenMetadataService ── share name, resolution, request-to-share
```

The [Architecture docs](https://tailscreen.dev/architecture/) walk through each Swift file in detail.

## Network protocol

One port — `7447` — on **both TCP and UDP**. Everything rides over Tailscale's WireGuard tunnel.

| Channel       | Transport | Purpose                                                              |
| :------------ | :-------- | :------------------------------------------------------------------- |
| Video         | UDP/7447  | RTP — HEVC (RFC 7798) or H.264 (RFC 6184). Lossy on purpose.         |
| Annotations   | TCP/7447  | Length-framed JSON. Reliable on purpose.                             |
| Metadata      | TCP/7447  | Share name, resolution, request-to-share prompts.                    |
| Discovery     | TCP/7447  | Probe across the tailnet to find Tailscreen peers.                   |

The sharer prefers HEVC and falls back to H.264 if VideoToolbox refuses it (Intel Macs without HW HEVC). The viewer auto-detects from the **RTP payload type** — `97` for HEVC, `96` for H.264 — so there's no out-of-band negotiation. Parameter sets go in-band on every IDR frame: SPS+PPS for H.264, VPS+SPS+PPS for HEVC, so a late-joining viewer can spin up a decoder without a handshake. Keyframes roughly every 2s, or earlier on a PLI from the receiver. UDP loss is fine — that's the trade we wanted.

The same UDP socket also carries tiny one-byte control messages from viewer to sharer: HELLO, KEEPALIVE, BYE, PLI. RTP packets always start with `0x80`-`0xBF` (V=2), so the leading byte unambiguously distinguishes the two.

The annotation and metadata channels share the TCP socket on the same port, with a 1-byte type prefix and a 4-byte big-endian length. The full wire format is in [`Sources/ScreenShareProtocol.swift`](Sources/ScreenShareProtocol.swift). Why TCP for annotations? Because dropping a stroke segment is visible and confusing; dropping a video frame is invisible. The transport choice tracks the cost of loss.

More detail in the [Network Protocol docs](https://tailscreen.dev/protocol/).

> There's a legacy single-stream framing (`[size:4][keyframe:1][data:N]`) in `Sources/ScreenShareServer.swift` and `Sources/ScreenShareClient.swift`. That's the **non-Tailscale** code path, kept as reference. The active path is everything described above.

## Privacy & security

- **Encrypted.** All four channels ride inside Tailscale's WireGuard tunnel. There is no plaintext fallback and no separate Tailscreen-level TLS layer.
- **No server.** The authors don't operate any infrastructure that touches your traffic. Tailscale's control plane and DERP relays are the only third-party components, and DERP can't decrypt your traffic — it's a TLS dumb pipe carrying ciphertext.
- **No recording.** Pixels are captured, encoded, transmitted, and discarded. Nothing on disk except the ephemeral tsnet node state, which lives at `~/Library/Application Support/Tailscreen/tailscale`.
- **Ephemeral nodes.** Tailscale removes the node when the session ends.
- **Tailscale ACLs are your access-control plane.** Allow TCP+UDP/7447 from the principals you trust; reject everyone else.

[Privacy & Security docs](https://tailscreen.dev/security/).

## Performance

Tailscale will try really hard to give you a direct WireGuard connection. When that works, latency is essentially the round-trip time between the two machines. When it falls back to a DERP relay, you'll feel it.

- Wired Ethernet > Wi-Fi for the most consistent latency. This is the single biggest fix.
- Disable Wi-Fi power saving.
- Check `tailscale status` — `direct` is what you want. `relay "..."` means DERP.
- Pause large background uploads (cloud sync, backups) while you're sharing — they can crowd out the video stream.

## Troubleshooting

The full list lives in the [Troubleshooting docs](https://tailscreen.dev/troubleshooting/). The greatest hits:

- **"Permission Denied" capturing the screen.** Toggle **System Settings → Privacy & Security → Screen Recording**, then *quit and relaunch* Tailscreen. macOS doesn't push the new permission to a running process.
- **"Connection Failed".** Check that Tailscale itself works first (`tailscale ping <hostname>`), and that your ACLs allow TCP+UDP/7447. Copying the hostname from **Show Tailscale Info** avoids easy-to-miss typos.
- **Black viewer window.** **Disconnect** and reconnect — that forces a fresh keyframe.
- **Build fails with linker errors.** This usually means `libtailscale.a` hasn't been built yet. Run `make build` once, then `swift build` works.

## CI/CD

- `.github/workflows/build.yml` — `make build` + `make test` on every PR and push.
- `.github/workflows/release.yml` — fires on a published release. Cross-builds a universal binary, codesigns and notarizes when secrets are present, uploads the zip + checksums.
- `.github/workflows/pages.yml` — builds and deploys the docs site when `docs/` changes.

To cut a release:

```bash
git tag v1.0.0
git push origin v1.0.0
# then: GitHub UI → Releases → publish the draft
```

## License

[MIT](LICENSE). The upstream `libtailscale` is BSD-3-Clause.
