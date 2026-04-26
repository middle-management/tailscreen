---
title: Home
layout: home
nav_order: 1
permalink: /
---

# Tailscreen
{: .fs-9 }

Encrypted, low-latency, peer-to-peer screen sharing over Tailscale — a tiny macOS menubar app.
{: .fs-6 .fw-300 }

[Install]({% link install.md %}){: .btn .btn-primary .fs-5 .mb-4 .mb-md-0 .mr-2 }
[View on GitHub](https://github.com/middle-management/tailscreen){: .btn .fs-5 .mb-4 .mb-md-0 }

---

Tailscreen is a minimal macOS menubar app for high-quality, low-latency screen
sharing using Tailscale's encrypted peer-to-peer network. It uses ephemeral
tsnet nodes (no manual device registration), captures with ScreenCaptureKit,
encodes H.264 with VideoToolbox, and renders with Metal. Built with Swift
Package Manager — no Xcode project required.

## Features

- **Menubar Integration** — lightweight app that stays out of your way.
- **Tailscale Integration** — secure, encrypted peer-to-peer connections.
- **Automatic Peer Discovery** — browse and connect to shares on your tailnet
  with one click.
- **Zero Configuration** — no port forwarding or firewall setup.
- **High Quality** — hardware-accelerated H.264 via VideoToolbox.
- **Low Latency** — optimized for real-time streaming.
- **Retina Support** — captures and streams at native 2× resolution.
- **60 FPS** — smooth, hardware-paced capture.
- **Works Anywhere** — share across networks, not just LAN.

## Requirements

- macOS 15.0 (Sequoia) or later
- Swift 6.0 or later
- Screen Recording permission
- Tailscale account (free for personal use)

## Where next?

| If you want to...                                      | Go here                                                     |
| :----------------------------------------------------- | :---------------------------------------------------------- |
| Build and run Tailscreen                               | [Install]({% link install.md %})                            |
| Share or view a screen for the first time              | [Usage]({% link usage.md %})                                |
| Understand the components and data flow                | [Architecture]({% link architecture.md %})                  |
| Read the wire protocol                                 | [Network Protocol]({% link protocol.md %})                  |
| Check what's encrypted and what isn't                  | [Privacy & Security]({% link security.md %})                |
| Diagnose a black screen or connection failure          | [Troubleshooting]({% link troubleshooting.md %})            |
| Hack on the codebase                                   | [Contributing]({% link contributing.md %})                  |

## License

[MIT](https://github.com/middle-management/tailscreen/blob/main/README.md). The
upstream `libtailscale` C library is BSD-3-Clause.
