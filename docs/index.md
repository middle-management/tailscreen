---
title: Home
layout: home
nav_order: 1
permalink: /
---

# Tailscreen
{: .fs-9 }

Screen sharing for people who don't want to install Zoom on their Mac to look at a friend's terminal for ten seconds.
{: .fs-6 .fw-300 }

[Install]({% link install.md %}){: .btn .btn-primary .fs-5 .mb-4 .mb-md-0 .mr-2 }
[View on GitHub](https://github.com/middle-management/tailscreen){: .btn .fs-5 .mb-4 .mb-md-0 }

---

Tailscreen is a tiny macOS menubar app that streams one Mac's screen to
another Mac over [Tailscale](https://tailscale.com/). It uses ScreenCaptureKit
to grab pixels, VideoToolbox to encode H.264, and Tailscale's WireGuard tunnel
to move bytes. There is no server. There is no account to make (other than
Tailscale itself, which you probably already have). There is no port to
forward.

You hit "Start Sharing", the other person hits "Browse Shares", they click
your machine, and a window opens. That's the whole thing.

## What you get

- A 60 fps, full-Retina H.264 stream over the same WireGuard tunnel that
  Tailscale already gives you. Direct peer-to-peer when the network allows;
  Tailscale's DERP relays when it doesn't.
- Automatic peer discovery — Tailscreen probes your tailnet and shows you
  which machines are sharing. No IP-typing.
- Ephemeral tsnet nodes. Each session spins up a fresh node and tears it down
  when you're done, so your Tailscale admin console doesn't fill up with
  ghosts.
- Two-way annotations. The viewer can scribble on the sharer's screen over a
  reliable TCP back-channel, so strokes don't get dropped when video does.
- A menubar icon. That's it for UI. No dock icon, no main window, nothing
  bouncing for attention.

## What you need

- macOS 15 (Sequoia) or later. Not 14, not iOS, not Linux.
- Swift 6 toolchain if you're building from source. Otherwise just grab a
  release.
- A Tailscale account. The free personal tier is fine.
- Screen Recording permission. macOS will ask the first time you share.

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
