---
title: Privacy & Security
nav_order: 6
permalink: /security/
---

# Privacy & security

The short version: we don't run a server, we don't see your traffic, your
pixels go directly between two Macs over Tailscale's WireGuard tunnel, and
nothing is recorded. The longer version is below.

## What's encrypted

Everything. All four channels documented in
[Network Protocol]({% link protocol.md %}) — video, annotations, metadata,
discovery probes — go through Tailscale's WireGuard tunnel. There is no
plaintext fallback and there is no separate Tailscreen-level TLS layer.
WireGuard is the security boundary; everything we send rides inside it.

If you're wondering "what cipher" or "what key exchange", that's
WireGuard's answer to give, not ours: ChaCha20-Poly1305 and Curve25519
Noise IK. Those choices are Tailscale's; we benefit from them.

## We don't run a server

There is no Tailscreen Inc., no Tailscreen-cloud, no telemetry endpoint,
no "phone home". The authors don't operate any infrastructure that touches
your traffic. The only third-party service in the picture is **Tailscale**,
which you've already opted into separately. Specifically:

- The Tailscale **control plane** issues the ephemeral node identity and
  exchanges the WireGuard public keys. It never sees session traffic.
- Tailscale **DERP relays** can carry your encrypted bytes when direct
  P2P fails. They cannot decrypt them — DERP is end-to-end encrypted on
  top of being a TLS dumb pipe.
- That's it.

If you don't trust Tailscale, you should not be using Tailscreen, because
Tailscreen's security properties are downstream of Tailscale's. We didn't
re-implement WireGuard.

If you'd rather not trust Tailscale's *hosted* control plane specifically,
you can point Tailscreen at a self-hosted
[headscale](https://github.com/juanfont/headscale) instance — see
[Self-hosted control planes]({% link self-hosted.md %}). The WireGuard
trust story is unchanged either way.

## Nothing is stored

No frame buffers, no annotations, no transcripts, nothing. Pixels go from
ScreenCaptureKit → encoder → wire → decoder → display and are then
discarded. The only on-disk state Tailscreen creates is the tsnet node
state at `~/Library/Application Support/Tailscreen/tailscale`, which holds
the ephemeral node's machine key. You can `rm -rf` it any time. (Doing so
will force a fresh login the next time you start sharing.)

## Ephemeral nodes

Each `Start Sharing` or `Connect to...` session spins up a fresh tsnet
ephemeral node. When the session ends — explicitly via "Stop Sharing", or
implicitly when the process exits — Tailscale removes the node from your
tailnet automatically. You will not accumulate phantom devices in your
admin console no matter how many times you start and stop.

## The macOS Screen Recording prompt

macOS forces an explicit user grant before any process can read pixels
from the display server. Tailscreen requests Screen Recording the first
time you press **Start Sharing**, the OS prompts you, and the permission
takes effect after the next launch — macOS doesn't apply it to a process
that's already running, so a restart is required.

Revoking the permission in **System Settings → Privacy & Security →
Screen Recording** immediately kills capture. There's no override.

## Access control

If you want to be picky about who on your tailnet can connect to your
shares, use Tailscale ACLs. The relevant rule is "allow TCP and UDP to
port 7447 from the principals you trust." Anyone whose connection your
ACLs reject can't reach Tailscreen, full stop — even if they're on the
same tailnet as you. This is the right place to put fine-grained access
control: tailnet ACLs are visible, auditable, and centralized.

## Things we do not protect against

We're not in the business of pretending Tailscreen is a defense against
threats it cannot defend against. Things outside the threat model:

- **Local user compromise.** Anyone with an active session on the sharing
  Mac can already see the screen. We can't help you there.
- **Malicious code in the Tailscreen process.** No sandboxing beyond what
  macOS itself enforces on a signed app. If you're worried about supply-
  chain attacks, build from source.
- **Compromised Tailscale credentials.** If an attacker can join your
  tailnet, they're inside your perimeter and ACLs are your only line of
  defense. Use them.
- **An adversary in your physical line of sight.** Yes, this is silly to
  say, but they can read your screen with their eyes.
