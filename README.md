<p align="center">
  <img src="docs/assets/logo.svg" alt="Tailscreen logo" width="180">
</p>

# Tailscreen

[![Build Status](https://github.com/middle-management/tailscreen/actions/workflows/build.yml/badge.svg)](https://github.com/middle-management/tailscreen/actions/workflows/build.yml)

📖 **Documentation:** <https://tailscreen.dev>

Lightweight screen sharing between your own machines, for the times when spinning up a full conferencing app feels like overkill.

Tailscreen streams one machine's screen to another over [Tailscale](https://tailscale.com/). There is no server, no port to forward, and no account to create beyond Tailscale itself.

You click your display, the other person clicks your machine in their device list, a window opens. That's the whole thing.

## What you get

- Hardware-encoded HEVC or H.264 over the same WireGuard tunnel Tailscale already gives you — up to 60 fps at full Retina resolution on macOS. Direct peer-to-peer when the network allows; Tailscale's DERP relays when it doesn't.
- Automatic peer discovery — Tailscreen probes your tailnet and lists which machines are sharing. No IP-typing.
- Ephemeral tsnet nodes. Each session spins up a fresh node and Tailscale tears it down when you're done; your admin console doesn't fill up with ghosts.
- Two-way annotations over a reliable TCP back-channel, so strokes don't get dropped when video does.
- Opt-in remote control, granted to one viewer at a time and revocable instantly (including a panic hotkey).
- Small, ordinary desktop apps — on macOS, a window for finding peers plus a menubar icon carrying the sharing controls.

## Platforms

| | Share | View | Capture | Download |
| :--- | :--- | :--- | :--- | :--- |
| **macOS** 15.2+ | ✅ | ✅ | ScreenCaptureKit | signed + notarized `.app` |
| **Linux** | ✅ | ✅ | X11 (`libxcb`) | AppImage + tarball, x86_64 and aarch64 |
| **Windows** 10/11 | ✅ | ✅ | Windows.Graphics.Capture | zip + MSIX, x64 and arm64 |

macOS is the mature one and the only platform whose downloads are signed by a trusted authority. The Linux and Windows apps are newer: they build, ship artifacts, and are gated in CI on real work (a headless GL render self-test on Linux; MSIX install-and-launch on Windows), but they've had far less time in front of real users. Wayland can't be *shared* from yet — capture is X11-only — and the Windows MSIX is self-signed, so it installs only after you trust its certificate.

## What you need

- A Tailscale account, or a self-hosted control plane like [headscale](https://github.com/juanfont/headscale). The free Tailscale personal tier is fine; see [Self-hosted control planes](https://tailscreen.dev/self-hosted/) if you'd rather not depend on Tailscale Inc.
- Swift 6 toolchain if you're building from source. Otherwise just grab a release.
- Screen Recording permission on macOS — it'll ask the first time.

## Install

### Homebrew

```bash
brew install --cask middle-management/tap/tailscreen
```

On macOS this pulls the signed, notarized universal build from the latest release; on Linux the *same* cask links the release AppImage instead, branching on `on_macos` / `on_linux`. The formula lives in [middle-management/homebrew-tap](https://github.com/middle-management/homebrew-tap).

### From a release

Everything is attached to the same [GitHub release](https://github.com/middle-management/tailscreen/releases).

- **macOS** — `Tailscreen-<version>-macOS.zip`. Unzip, drag to `/Applications`. Universal binary, signed and notarized when the build secrets are configured.
- **Linux** — `Tailscreen-<version>-<x86_64|aarch64>.AppImage`; `chmod +x` and run. AppImages need FUSE to self-mount, so `Tailscreen-<version>-linux-<x86_64|arm64>.tar.gz` is there for systems without it.
- **Windows** — `Tailscreen-<version>-windows-<x64|arm64>.zip`, which is unzip-and-run. There's also an `.msix`, but it is **self-signed**: Windows rejects it until you trust the certificate, so the zip is the easier path. Proper signing (and winget) is pending.

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
make release      # → Apps/macOS/.build/release/Tailscreen
make install      # → ~/bin/Tailscreen
```

The `Makefile` targets build the **macOS** app. The other two live beside it and are built directly:

```bash
swift build --package-path Apps/linux   --product tailscreen   # needs GTK4 + libav* + ALSA
swift build --package-path Apps/windows --product tailscreen   # needs the Windows App SDK
```

Both still want `make tailscale` first, for the same `libtailscale.a`. Per-platform prerequisites are in [`Apps/linux/README.md`](Apps/linux/README.md) and [`Apps/windows/README.md`](Apps/windows/README.md). More detail in the [Install docs](https://tailscreen.dev/install/).

## Run it

```bash
cd Apps/macOS && swift run                 # or: make run
Apps/macOS/.build/release/Tailscreen       # after `make release`
```

On Linux and Windows the executable is `tailscreen`; run it with no arguments to get the peer list, or pass a hostname to dial it directly.

## Repo layout

```
Apps/          one runnable app per platform — linux, macOS, windows
               (each owns its own packaging/ where it has any)
Packages/      local SwiftPM packages: the portable protocol core
               (TailscreenKit), the per-platform backends, and the
               system-library wrappers
scripts/       build, packaging and end-to-end helpers
docs/          the tailscreen.dev site
```

The interesting split is `Packages/TailscreenKit`: the wire protocol, the viewer and sharer data planes, and every pure decision they make live there, build on Linux, and are unit-tested on Linux CI. Each app supplies only its platform's capture, encode, decode, render and audio behind those seams. [`CLAUDE.md`](CLAUDE.md) is the detailed map.

## Use it

### First launch

1. Click the 📺 in the menubar.
2. **Sign in with Tailscale** — opens a browser tab to authenticate the ephemeral tsnet node against your tailnet.

You stay signed in across restarts. The identity footer at the bottom of the panel shows who you are; click it to sign out.

### Sharing

1. Click the 📺.
2. Under **SHARE A DISPLAY**, click the display you want to share. On the very first share, macOS will ask for Screen Recording permission — approve it, then quit and relaunch (macOS doesn't push the new permission to a running process).
3. The panel switches to a green "Sharing your screen" card with a live thumbnail. **Stop Sharing** ends the session; **Draw** opens the annotation overlay.

### Viewing

1. Click the 📺.
2. Tailscreen auto-populates the **DEVICES** list with peers on your tailnet (refresh with the ⟳ button). Online peers show a green dot.
3. Click a device row to connect. A viewer window opens.

The panel switches to a "Viewing *hostname*" card. **Disconnect** there or close the window to end the session.

Ephemeral tsnet nodes get torn down automatically — nothing to clean up in the Tailscale admin console.

## Testing on one Mac

You can exercise the full peer-discovery path on a single machine:

```bash
./test-local.sh        # 2 instances
./test-local.sh 3      # N instances
```

Each child gets `TAILSCREEN_INSTANCE=<i>`, which suffixes the Tailscale state directory and hostname. **This step matters.** If two processes share the state dir at `~/Library/Application Support/Tailscreen/tailscale`, they reuse the same machine key, the tailnet treats them as the same device, and the **DEVICES** list comes back empty. It's by far the most common cause of an empty peer list when testing locally.

This setup tests Tailscale integration and peer discovery. It does **not** test NAT traversal — both processes share the same network stack. For that, use two actual machines.

### Local screen-share E2E

Beyond the interactive `test-local.sh`, there's an asserted end-to-end suite for things CI can't cover (GitHub Actions macOS runners can't grant Screen Recording TCC):

```bash
make test-e2e-local     # XCTest: synthetic frames + real capture-helper + picker smoke
make test-e2e-harness   # Two real Tailscreen instances, asserted by log marker
```

First run of either pops a Screen Recording permission prompt on `Apps/macOS/.build/debug/Tailscreen`; grant it and re-run. See [CLAUDE.md](CLAUDE.md#local-screen-share-e2e-local-only) for the env-var hooks the harness uses.

Linux has its own asserted equivalent — `scripts/e2e-linux-sharer.sh` brings up a local headscale and an Xvfb display, runs a real sharer and a headless viewer, and checks not just that frames arrived but that they're **non-uniform**, i.e. actual captured pixels rather than a flat rectangle a frame count would happily accept.

### Voice (manual)

Two-way voice rides on the same UDP socket as video, gated to active share sessions. Both ends are muted by default — unmute via the toolbar mic button (viewer) or **File → Microphone** (sharer). The first unmute prompts for microphone access; macOS uses VoiceProcessingIO for built-in echo cancellation.

To verify:

1. Start two instances locally: `./test-local.sh 2`.
2. Sharer: open the menubar → **Share my screen**.
3. Viewer (other instance): open the menubar → connect to the sharer.
4. On the viewer, click the toolbar mic icon. Grant microphone access on the prompt.
5. Speak. The sharer should hear you (use headphones to keep AEC honest).
6. On the sharer, open **File → Microphone**. Speak. The viewer should hear you.
7. Add a third instance (`./test-local.sh 3`) and have all three speak in turn — each should hear the other two without echo. The sharer relays audio between viewers without transcoding (SFU-style); each receiver decodes per-SSRC and mixes locally.

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

The annotation and metadata channels share the TCP socket on the same port, with a 1-byte type prefix and a 4-byte big-endian length. Why TCP for annotations? Because dropping a stroke segment is visible and confusing; dropping a video frame is invisible. The transport choice tracks the cost of loss.

More detail in the [Network Protocol docs](https://tailscreen.dev/protocol/).

## Privacy & security

- **Encrypted.** All four channels ride inside Tailscale's WireGuard tunnel. There is no plaintext fallback and no separate Tailscreen-level TLS layer.
- **No server.** The authors don't operate any infrastructure that touches your traffic. Tailscale's control plane and DERP relays are the only third-party components, and DERP can't decrypt your traffic — it's a TLS dumb pipe carrying ciphertext.
- **No recording.** Pixels are captured, encoded, transmitted, and discarded. Nothing on disk except the ephemeral tsnet node state — `~/Library/Application Support/Tailscreen/tailscale` on macOS, `$XDG_CONFIG_HOME/tailscreen` (or `~/.config/tailscreen`) on Linux, `%LOCALAPPDATA%\Tailscreen` on Windows.
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
- **"Connection Failed".** Check that Tailscale itself works first (`tailscale ping <hostname>`), and that your ACLs allow TCP+UDP/7447. If a peer is missing from the **DEVICES** list, hit the ⟳ refresh button — discovery probes can race with peers coming online.
- **Black viewer window.** **Disconnect** and reconnect — that forces a fresh keyframe.
- **Build fails with linker errors.** This usually means `libtailscale.a` hasn't been built yet. Run `make build` once, then `swift build` (from `Apps/macOS/`) works.

## CI/CD

CI builds and tests on every PR — the macOS app plus the Linux and Windows apps and every portable package, with the portable tier's suites running on Linux.

A published GitHub release runs one workflow that fans out to a job per deliverable: the universal macOS `.app` (codesigned and notarized when the Apple secrets are configured), Linux AppImages and tarballs for both arches, and Windows zips and MSIXes for both arches. Packaging is slow enough that it can't be a required gate, so it's also runnable on demand by labelling a PR `build-linux-package`, `build-windows-package` or `build:notarized`. Docs deploy when `docs/` changes.

To cut a release:

```bash
git tag v1.0.0
git push origin v1.0.0
# then: GitHub UI → Releases → publish the draft
```

## License

[MIT](LICENSE). The upstream `libtailscale` is BSD-3-Clause.
