---
title: Home
layout: home
nav_order: 1
permalink: /
---

<div class="ts-hero">
  <img src="{{ '/assets/logo.svg' | relative_url }}" alt="Tailscreen logo">
  <h1>Tailscreen</h1>
  <p class="ts-hero-tagline">Encrypted, low-latency screen sharing between
  Macs — over your own Tailscale network, with no server in the middle.</p>
  <p class="ts-hero-actions">
    <a href="{% link install.md %}" class="btn btn-primary fs-5">Install</a>
    <a href="https://github.com/middle-management/tailscreen" class="btn fs-5">View on GitHub</a>
  </p>
</div>

---

Tailscreen is a tiny macOS menubar app that streams one Mac's screen to
another Mac over [Tailscale](https://tailscale.com/). It uses ScreenCaptureKit
to grab pixels, VideoToolbox to encode HEVC (with H.264 as a fallback for
older hardware), and Tailscale's WireGuard tunnel to move bytes. There is no
server. There is no account to make beyond Tailscale itself. There is no port
to forward.

You hit "Start Sharing", the other person hits "Browse Shares", they click
your machine, and a window opens. That's the whole thing.

## What you get

<div class="ts-feature-grid">
  <div class="ts-card">
    <h3>60 fps, full-Retina video</h3>
    <p>Hardware-encoded HEVC (H.264 fallback), wide color on P3 displays,
    and loss recovery via selective retransmission, forward error
    correction, and adaptive bitrate/frame-rate control.</p>
  </div>
  <div class="ts-card">
    <h3>Peer-to-peer by default</h3>
    <p>Direct WireGuard between the two Macs when the network allows,
    Tailscale's DERP relays when it doesn't. No port forwarding, ever.</p>
  </div>
  <div class="ts-card">
    <h3>Viewer approval, on by default</h3>
    <p>Nobody sees your screen until you Accept them — and you can remember
    peers as Always Allow or Deny &amp; Block.</p>
  </div>
  <div class="ts-card">
    <h3>Automatic peer discovery</h3>
    <p>Tailscreen probes your tailnet and shows you which machines are
    sharing. No IP-typing.</p>
  </div>
  <div class="ts-card">
    <h3>Voice &amp; system audio</h3>
    <p>Talk over the same tunnel, and share what your Mac is playing —
    viewers hear both, with one mute button each.</p>
  </div>
  <div class="ts-card">
    <h3>Two-way annotations</h3>
    <p>The viewer can scribble on the sharer's screen over a reliable TCP
    back-channel, so strokes don't get dropped when video does.</p>
  </div>
  <div class="ts-card">
    <h3>A real viewer window</h3>
    <p>Cursor-anchored zoom and pan, a live stats overlay, and quality
    presets when you'd rather trade fidelity for bandwidth.</p>
  </div>
  <div class="ts-card">
    <h3>Opt-in remote control</h3>
    <p>A viewer can request your mouse and keyboard; you grant per session,
    revoke with one click (or the ⌃⌥. panic hotkey), and it's off the
    moment they disconnect.</p>
  </div>
  <div class="ts-card">
    <h3>Ephemeral tsnet nodes</h3>
    <p>Each session spins up a fresh node and tears it down when you're
    done, so your Tailscale admin console doesn't fill up with ghosts.</p>
  </div>
</div>

And the whole UI is a menubar icon. No dock icon, no main window, nothing
bouncing for attention.

## What you need

- macOS 15 (Sequoia) or later. Earlier macOS versions, iOS, and Linux aren't supported.
- Swift 6 toolchain if you're building from source. Otherwise just grab a
  release.
- A Tailscale account. The free personal tier is fine.
- Screen Recording permission. macOS will ask the first time you share.
  (Accessibility too, but only if you ever grant a viewer remote control.)

## Where to go next

| You want to...                                  | Read this                                        |
| :---------------------------------------------- | :----------------------------------------------- |
| Get it running                                  | [Install]({% link install.md %})                 |
| Actually use it                                 | [Usage]({% link usage.md %})                     |
| See how the pieces fit together                 | [Architecture]({% link architecture.md %})       |
| Read the wire format                            | [Network Protocol]({% link protocol.md %})       |
| Confirm nobody else is watching                 | [Privacy & Security]({% link security.md %})     |
| Diagnose a black viewer window                  | [Troubleshooting]({% link troubleshooting.md %}) |
| Hack on it                                      | [Contributing]({% link contributing.md %})       |

## License

[MIT](https://github.com/middle-management/tailscreen/blob/main/LICENSE).
The upstream `libtailscale` is BSD-3-Clause. Do whatever.
