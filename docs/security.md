---
title: Privacy & Security
nav_order: 6
permalink: /security/
---

# Privacy & security

## What's encrypted

All traffic between Tailscreen peers is encrypted by Tailscale's WireGuard
tunnel. There is no plaintext fallback, and no separate Tailscreen-level
TLS — the WireGuard tunnel is the security boundary.

That covers all four channels documented in
[Network Protocol]({% link protocol.md %}):

- Video (UDP/7447 RTP H.264).
- Annotations (TCP/7447, length-prefixed JSON).
- Metadata (TCP/7447, request/response).
- Discovery probes (TCP/7447).

## Peer-to-peer by default

Tailscale prefers a direct WireGuard connection between the two devices.
When NAT or firewall rules prevent that, it falls back to a DERP relay
operated by Tailscale Inc. — DERP traffic is still end-to-end encrypted; the
relay only sees ciphertext.

There is **no central Tailscreen server**. Anthropic / Middle Management /
the Tailscreen authors do not run any infrastructure that touches your
video, annotations, or metadata.

## What's stored

Nothing. Frames are captured, encoded, transmitted, and discarded — there is
no on-disk recording. The Tailscale state directory under
`~/Library/Application Support/Tailscreen/tailscale` holds the ephemeral
node's machine key and tailnet identity; that's it.

## Ephemeral nodes

Each `Start Sharing` / `Connect to...` session spins up a fresh tsnet
ephemeral node. When the session ends, Tailscale automatically removes the
node from your tailnet — no stale devices accumulate in the Tailscale admin
console.

## macOS Screen Recording permission

macOS forces an explicit user grant before any process can read pixel data
from the display server. Tailscreen requests Screen Recording the first
time you press **Start Sharing**, and the OS prompts you in
**System Settings → Privacy & Security → Screen Recording**. Revoking the
permission immediately blocks capture.

## Access control

Use Tailscale ACLs to restrict who on your tailnet can reach Tailscreen.
The relevant rule is "allow TCP and UDP to port 7447 from the principals you
trust." Anything not permitted by your tailnet ACLs cannot connect — even
if they're on the same tailnet.

## Threats not in scope

Tailscreen does not defend against:

- A compromised macOS user account on the sharing or viewing machine —
  someone with local access can already see the screen.
- Malicious code running inside the Tailscreen process. No sandboxing
  beyond what macOS provides for an unsigned/signed app.
- Compromised Tailscale credentials. If an attacker can join your tailnet,
  ACLs are your only line of defense.
