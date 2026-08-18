---
title: Privacy & Security
nav_order: 7
permalink: /security/
---

# Privacy & security

The short version: we don't run a server, we don't see your traffic, your
pixels go directly between two machines over Tailscale's WireGuard tunnel,
nothing is recorded, nobody sees your screen without your approval, and
nobody controls your machine without an explicit per-session grant. The
longer version is below.

## What's encrypted

Everything. Every channel documented in
[Network Protocol]({{ site.baseurl }}{% link protocol.md %}) — video, audio, annotations,
remote-control input, metadata, discovery probes — goes through
Tailscale's WireGuard tunnel. There is no plaintext fallback and there is
no separate Tailscreen-level TLS layer. WireGuard is the security
boundary; everything we send rides inside it.

Cipher and key exchange are WireGuard's department — ChaCha20-Poly1305
and Curve25519 Noise IK. Those choices are Tailscale's; we inherit them.

The division of labor: **Tailscale provides encryption, peer
authentication, and network reachability. Tailscreen provides the
authorization layer on top** — who may view, who may control, and how
much of anything a peer can make you buffer. The rest of this page is
about that layer.

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
[Self-hosted control planes]({{ site.baseurl }}{% link self-hosted.md %}). The WireGuard
trust story is unchanged either way.

## Nothing is stored

No frame buffers, no annotations, no transcripts, nothing. Pixels go from
capture → encoder → wire → decoder → display and are then
discarded. The on-disk state Tailscreen creates is: the tsnet node state
(`~/Library/Application Support/Tailscreen/tailscale` on macOS,
`~/.config/tailscreen` on Linux — the ephemeral node's machine key; you
can delete it any time, which forces a fresh login), and your preferences,
which include the viewer allow/deny list described below.

## Ephemeral nodes

Each sharing or viewing session spins up a fresh tsnet
ephemeral node. When the session ends — explicitly via "Stop Sharing", or
implicitly when the process exits — Tailscale removes the node from your
tailnet automatically. You will not accumulate phantom devices in your
admin console no matter how many times you start and stop.

## Who can see your screen

Being on the same tailnet is necessary but — by default — not sufficient.
Viewer admission runs through three checks, strictest first:

1. **The block list.** A peer you've hit "Deny & Block" on is rejected
   outright — even if you later turn the approval gate off, and even if
   they're already connected when you block them (blocking expels).
2. **The allow list.** A peer you've hit "Always Allow" on is admitted
   automatically.
3. **The approval gate.** Everyone else waits, seeing nothing, until you
   Accept or Deny. **"Require approval for new viewers" is on by
   default** — a fresh install never streams pixels to anyone without a
   click from you.

Two implementation details that matter for trusting this:

- The remembered allow/deny list is keyed by the peer's **stable
  Tailscale node ID**, resolved by the sharer's own query to its local
  Tailscale API — never by anything the peer claims about itself on the
  wire. A blocked peer can't come back by renaming its machine, and a
  wire payload can't impersonate an allowed one.
- In-session decisions (which connection is pending, which is admitted)
  are keyed by the peer's tailnet source IP — which WireGuard
  authenticates — not by any self-reported hostname.

Denied viewers get told they were declined (rather than left guessing),
and pending viewers see a waiting state, not your screen. An admitted
viewer can also be removed at any moment: the ✕ on its row in the sharing
card disconnects it one-time (it can return through the checks above),
while "Deny & Block" both expels and remembers.

`TAILSCREEN_OPEN_DOOR=1` forces the approval gate off for scripted
testing. Never set it in production; note that even it does not override
the block list.

Admission controls *who* sees your screen; **Cloaked Apps** (Settings →
Cloaked Apps) controls *what* even admitted viewers see. Apps on the
cloak list are excluded from every whole-display share at the capture
layer — their pixels are never delivered to the encoder, so nothing
sensitive is encoded, sent, and blurred after the fact; it's simply never
captured. Two honest caveats: a cloaked app that launches mid-share can
be visible for a moment (typically under a couple of seconds) while the
capture filter is rebuilt to include it, and cloaking is a
tidy-screen/anti-oops measure for display shares — if you explicitly pick
a cloaked app to share, your deliberate choice wins.

## Who can control your machine

Remote control is off until granted, per session, per viewer:

- **Only admitted viewers can even ask.** A control request from a peer
  that isn't an approved, connected viewer is dropped before it reaches
  any UI. If you turn off **Allow control requests** in Settings, requests
  from everyone are declined automatically and silently.
- **Exactly one grantee at a time**, identified by the server-assigned ID
  of the specific TCP connection the grant was issued to. Input events
  from any other connection — including a reconnect by the same peer —
  are discarded. Granting a second viewer revokes the first.
- **Grants die with the session.** Disconnection, the viewer's own
  release, or Stop Sharing all auto-revoke. The sharer can revoke
  instantly at any moment: the Stop button, File → Stop Remote Control,
  or (on macOS) the **⌃⌥.** panic hotkey, registered system-wide while a
  grant is live — so it works even when the controlling viewer has some
  other app focused on your machine.
- **Rate-limited.** Injected events pass a per-grant rate ceiling, so a
  compromised or misbehaving viewer can't flood synthetic input.
- **Pointer is scoped, keyboard is not — and we say so.** Mouse events
  are confined to the shared content's on-screen rectangle (for an app
  share, the union of that app's windows — not the whole display). But
  keystrokes land wherever the sharer's OS focus happens to be, because
  scoping keyboard input to one app can't be done reliably, and a scoping
  mechanism that sometimes leaks is worse than a disclosed absence of
  one. The grant button says so in as many words: granting gives full
  keyboard and mouse control of your entire computer — not just the shared
  window. Treat a grant accordingly, and prefer granting during
  display shares you're watching.
- **On macOS, the OS has a say too.** Injection requires the Accessibility
  permission, granted by you in System Settings. Without it, a grant is
  refused rather than silently installed. (On Linux, injection needs X11's
  XTEST extension — when it's absent the capability isn't advertised, so
  viewers aren't even offered the request rather than being granted
  control whose clicks vanish.)

## Resource-exhaustion bounds

A hostile peer on your tailnet shouldn't be able to crash Tailscreen even
if it can reach port 7447. The bounds that enforce that:

- **Framed TCP messages are capped at 1 MiB** of declared length; a peer
  declaring more is treated as a corrupt stream and disconnected. Nobody
  slow-streams a fake 4 GiB frame into your memory.
- **The pending-approval queue is capped and deduplicated per source
  IP**, so a flood of HELLOs or request-to-share prompts can't stack
  unbounded UI rows or pinned connections.
- **Send-side retransmit and FEC buffers are bounded** by age, bytes, and
  count; per-viewer retransmission spends from a token budget capped at a
  fraction of the video bitrate.
- **Remote-control input passes a rate ceiling** (see above), and
  annotation/control ops from non-admitted peers are dropped at the door.
- **Every parser facing peer bytes is fuzzed in CI** — random bytes,
  truncations, bit-flips, and length-field mutations, plus a longer
  nightly soak — so malformed input is a rejected packet, not a crash.

## The macOS permission prompts

macOS forces an explicit user grant before any process can read pixels
from the display server. Tailscreen requests Screen Recording the first
time you start a share, the OS prompts you, and the permission
takes effect after the next launch — macOS doesn't apply it to a process
that's already running, so a restart is required. Revoking the permission
in **System Settings → Privacy & Security → Screen Recording**
immediately kills capture. There's no override.

Remote control has its own, separate prompt: **Accessibility**, the macOS
permission for synthesizing input events. Tailscreen asks for it the
first time you grant control to a viewer, and refuses the grant until
it's given. If you never use remote control, never grant it.

## Access control at the network layer

If you want to be picky about who on your tailnet can *reach* Tailscreen
at all, use Tailscale ACLs. The relevant rule is "allow TCP and UDP to
port 7447 from the principals you trust." Anyone whose connection your
ACLs reject can't reach Tailscreen, full stop — even if they're on the
same tailnet as you. ACLs and the in-app approval gate compose: ACLs
decide who can knock, the gate decides who gets in.

## Things we do not protect against

No pretending Tailscreen defends against threats it can't. Outside the
threat model:

- **Local user compromise.** Anyone with an active session on the sharing
  machine can already see the screen. We can't help you there.
- **Malicious code in the Tailscreen process.** No sandboxing beyond what
  the OS itself enforces on a signed app. If you're worried about supply-
  chain attacks, build from source.
- **Compromised Tailscale credentials.** If an attacker can join your
  tailnet, they're inside your perimeter. The approval gate and block
  list still stand between them and your pixels, but ACLs are your
  first line of defense. Use them.
- **A viewer you granted control to.** Within the rate ceiling, a grantee
  can do what any keyboard-and-mouse user can do until you revoke. That's
  the feature. The disclosure at grant time and the panic hotkey are the
  mitigations; granting to someone you don't trust isn't mitigable.
- **An adversary in your physical line of sight.** Yes, this is silly to
  say, but they can read your screen with their eyes.
