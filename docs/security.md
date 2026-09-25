---
title: Privacy & Security
nav_order: 7
permalink: /security/
---

# Privacy & security

Short version: we don't run a server, we don't see your traffic, your
pixels go directly between two machines over Tailscale's WireGuard tunnel,
nothing is recorded, nobody sees your screen without your approval, and
nobody controls your machine without an explicit per-session grant. Detail
below.

## What's encrypted

Everything. Every channel in [Network Protocol]({{ site.baseurl }}{% link
protocol.md %}) — video, audio, annotations, remote-control input,
metadata, discovery probes — goes through Tailscale's WireGuard tunnel: no
plaintext fallback, no separate Tailscreen-level TLS layer. Cipher and key
exchange (ChaCha20-Poly1305, Curve25519 Noise IK) are WireGuard's, and
Tailscale's choice — we inherit them.

**Tailscale provides encryption, peer authentication, and network
reachability. Tailscreen provides the authorization layer on top** — who
may view, who may control, and how much a peer can make you buffer. The
rest of this page is about that layer.

## We don't run a server

No Tailscreen Inc., no Tailscreen-cloud, no telemetry endpoint, no "phone
home" — the authors operate no infrastructure that touches your traffic.
The only third party in the picture is **Tailscale**, which you've already
opted into separately:

- The Tailscale **control plane** issues the ephemeral node identity and
  exchanges WireGuard public keys. It never sees session traffic.
- Tailscale **DERP relays** can carry your encrypted bytes when direct P2P
  fails. They can't decrypt them — DERP is end-to-end encrypted on top of
  being a TLS dumb pipe.

If you don't trust Tailscale, you shouldn't use Tailscreen: its security
properties are downstream of Tailscale's, and we didn't re-implement
WireGuard. If you trust WireGuard but not Tailscale's *hosted* control
plane, point Tailscreen at a self-hosted
[headscale](https://github.com/juanfont/headscale) instance instead — see
[Self-hosted control planes]({{ site.baseurl }}{% link self-hosted.md %}).
The trust story is unchanged either way.

## Nothing is stored

No frame buffers, no annotations, no transcripts. Pixels go capture →
encoder → wire → decoder → display, then are discarded. The on-disk state
Tailscreen creates: the tsnet node's machine key
(`~/Library/Application Support/Tailscreen/tailscale` on macOS,
`~/.config/tailscreen` on Linux — delete it any time to force a fresh
login), and your preferences, including the viewer allow/deny list below.

## Ephemeral nodes

Each sharing or viewing session spins up a fresh tsnet ephemeral node. When
it ends — "Stop Sharing", or the process exiting — Tailscale removes the
node from your tailnet automatically. No phantom devices accumulate in
your admin console no matter how many times you start and stop.

## Who can see your screen

Being on the same tailnet is necessary but — by default — not sufficient.
Viewer admission runs three checks, strictest first:

1. **The block list.** A peer you've hit "Deny & Block" on is rejected
   outright — even if you later turn the approval gate off, even if
   they're already connected (blocking expels).
2. **The allow list.** A peer you've hit "Always Allow" on is admitted
   automatically.
3. **The approval gate.** Everyone else waits, seeing nothing, until you
   Accept or Deny. **On by default** — a fresh install never streams
   pixels to anyone without a click from you.

Two details that matter for trusting this: the remembered allow/deny list
is keyed by the peer's **stable Tailscale node ID**, resolved by the
sharer's own query to its local Tailscale API — never by anything the peer
claims on the wire, so a blocked peer can't return by renaming its machine
and a wire payload can't impersonate an allowed one. In-session decisions
(pending vs. admitted) are keyed by tailnet source IP, which WireGuard
authenticates — never a self-reported hostname.

Denied viewers are told so rather than left guessing; pending viewers see
a waiting state, not your screen. An admitted viewer can be removed any
time: the ✕ on its row disconnects it one-time (it can return through the
checks above), while "Deny & Block" both expels and remembers.

`TAILSCREEN_OPEN_DOOR=1` forces the approval gate off for scripted
testing — never set it in production, and note that even it doesn't
override the block list.

Admission controls *who* sees your screen; **Cloaked Apps** (Settings →
Cloaked Apps) controls *what* even admitted viewers see. Apps on the cloak
list are excluded from every whole-display share at the capture layer —
their pixels never reach the encoder, so there's nothing to blur after the
fact because it's never captured. Two caveats: a cloaked app launched
mid-share can be visible for a moment (typically under a couple of
seconds) while the capture filter rebuilds, and cloaking is a
tidy-screen/anti-oops measure — if you explicitly pick a cloaked app to
share, that deliberate choice wins.

## Guests: sharing outside the tailnet

**Share via Link** admits viewers who aren't on your tailnet at all. The
design principle: **a link is capability to knock, never capability to
watch.**

- **Same cryptography.** A guest connects over WireGuard via a handshake
  the token authenticates — the token embeds the share's public key and
  relay details, and the guest proves possession of its own key.
  End-to-end encryption and integrity match the tailnet path exactly; a
  relay (DERP) carrying the bootstrap or session sees only ciphertext.
- **Approval is mandatory, every join.** The three-check admission above
  collapses for guests: no remembered allow (nothing durable to key it
  on), the open-door toggle doesn't apply, and accepting a
  request-to-share doesn't pre-approve them. A link gets forwarded;
  whoever holds it still waits at your prompt, seeing nothing, every time.
- **A guest's identity is its key.** No Tailscale node ID, no trustworthy
  hostname — rows identify guests by a fingerprint of their WireGuard node
  key, the thing the tunnel actually authenticates. Denying one denylists
  that key at the tunnel for the life of the link, so a denied guest is
  silenced, not just declined.
- **Links are ephemeral by construction.** The guest key is generated
  fresh per link and never persisted: stopping the share, flipping the
  toggle off, or **New Link** destroys it, and with it every outstanding
  copy. There's no revocation list because there's nothing durable to
  revoke.
- **Guests bypass tailnet ACLs — knowingly.** The tunnel doesn't traverse
  your tailnet, so network-layer ACLs don't see it; the compensating
  controls are the mandatory approval, the per-link ephemeral key, and the
  tunnel-level deny above. **Settings → Link sharing** turns the feature
  off entirely if that trade is never acceptable in your deployment.
- **The token is a secret while the share runs** — treat it like a meeting
  link. The worst a leaked token enables is approval-prompt noise until
  you press New Link or stop sharing.
- **Guests can draw and ask to drive, behind the same gates as anyone
  else.** The framed control channel rides the guest tunnel, and every
  protection on it is identity-anchored, not tailnet-anchored: ops are
  honoured only from *admitted* viewers (an unapproved knocker reaches
  nothing), remote control needs your explicit per-request grant to
  exactly one connection, the grant dies with disconnect or revoke (panic
  hotkey included), and denying a guest severs their control channel with
  their tunnel. Only what "admission" means changes — for a guest it's
  your explicit approval every time.
- **A share can be link-only.** Started signed out, a share runs with the
  guest tunnel as its *only* transport: no Tailscale account, no control
  plane, no tailnet listener at all. Everything above applies unchanged;
  what disappears is surface, not protection.
- **A browser is a guest with two extra things to know.** The web form of
  a link opens a static page on `tailscreen.dev` running the same guest
  tunnel in WebAssembly — same handshake, approval, key identity and
  gates. The token rides the URL *fragment*, which a browser never sends
  to the server, so the hosting site never learns it, and the page is
  plain static files with nothing server-side to learn it with. What a
  browser *adds*: the JavaScript that decrypts your stream is served by
  whoever hosts the page (GitHub Pages, on our behalf, for the hosted
  URL) — a trust dependency the apps don't have. And a browser can't
  hole-punch, so every byte to it crosses a relay, as ciphertext, for the
  whole session.

## Who can control your machine

Remote control is off until granted, per session, per viewer:

- **Only admitted viewers can even ask.** A control request from anyone
  else is dropped before it reaches any UI; turning off **Allow control
  requests** in Settings declines every request automatically and
  silently.
- **Exactly one grantee at a time**, identified by the specific TCP
  connection's server-assigned ID. Input from any other connection —
  including a reconnect by the same peer — is discarded. Granting a
  second viewer revokes the first.
- **Grants die with the session** — disconnection, the viewer's own
  release, or Stop Sharing all auto-revoke. You can also revoke instantly:
  the Stop button, File → Stop Remote Control, or (macOS) the **⌃⌥.**
  panic hotkey, registered system-wide while a grant is live so it works
  even if some other app has focus.
- **Rate-limited**, so a compromised or misbehaving viewer can't flood
  synthetic input.
- **Pointer is scoped, keyboard is not — and we say so.** Mouse events are
  confined to the shared content's on-screen rectangle (for an app share,
  the union of its windows, not the whole display). Keystrokes land
  wherever OS focus happens to be — scoping keyboard input to one app
  can't be done reliably, and a mechanism that sometimes leaks is worse
  than a disclosed absence of one. The grant button says so directly:
  granting gives full keyboard and mouse control of your entire computer.
  Prefer granting during display shares you're watching.
- **On macOS, the OS has a say too.** Injection requires the Accessibility
  permission; without it a grant is refused, not silently installed. (On
  Linux, injection needs X11's XTEST extension — absent, the capability
  isn't advertised, so viewers aren't offered the request rather than
  granted control whose clicks vanish.)

## Resource-exhaustion bounds

A hostile peer on your tailnet shouldn't crash Tailscreen even if it can
reach port 7447:

- **Framed TCP messages are capped at 1 MiB** declared length; a peer
  declaring more is disconnected as a corrupt stream.
- **The pending-approval queue is capped and deduplicated per source IP**,
  so a flood of HELLOs or request-to-share prompts can't stack unbounded
  UI rows or pinned connections.
- **Send-side retransmit and FEC buffers are bounded** by age, bytes, and
  count; per-viewer retransmission spends from a token budget capped at a
  fraction of the video bitrate.
- **Remote-control input passes a rate ceiling** (see above), and
  annotation/control ops from non-admitted peers are dropped at the door.
- **Every parser facing peer bytes is fuzzed in CI** — random bytes,
  truncations, bit-flips, length-field mutations, plus a longer nightly
  soak — so malformed input is a rejected packet, not a crash.

## The macOS permission prompts

macOS requires an explicit grant before any process can read display
pixels. Tailscreen requests Screen Recording the first time you share; the
OS prompts you, and the grant takes effect only after the next launch — it
won't apply to an already-running process. Revoking it in **System
Settings → Privacy & Security → Screen Recording** kills capture
immediately; there's no override.

Remote control has its own prompt: **Accessibility**, for synthesizing
input events. Tailscreen asks for it the first time you grant control to
a viewer, and refuses the grant until it's given. Never use remote
control, never be asked.

## Access control at the network layer

To restrict who on your tailnet can *reach* Tailscreen at all, use
Tailscale ACLs: "allow TCP and UDP to port 7447 from the principals you
trust." A peer your ACLs reject can't reach Tailscreen, full stop, even on
the same tailnet. ACLs and the in-app approval gate compose — ACLs decide
who can knock, the gate decides who gets in.

## Things we do not protect against

- **Local user compromise.** Anyone with an active session on the sharing
  machine can already see the screen.
- **Malicious code in the Tailscreen process.** No sandboxing beyond what
  the OS enforces on a signed app. Worried about supply-chain attacks?
  Build from source.
- **The host serving the browser viewer.** A page is code downloaded every
  time you open it, from `tailscreen.dev` (GitHub Pages, built from this
  repository by a public workflow). Whoever controls that host, or your
  path to it, controls the code that decrypts the stream in that tab —
  the apps have no such dependency. If that matters, `make
  web-viewer-bundle` produces a single self-contained HTML file to host
  yourself or open from disk; and a guest you don't trust to pick their
  viewer is not a guest you should approve.
- **Compromised Tailscale credentials.** An attacker who joins your
  tailnet is inside your perimeter. The approval gate and block list still
  stand between them and your pixels, but ACLs are your first line of
  defense — use them.
- **A viewer you granted control to.** Within the rate ceiling, a grantee
  can do what any keyboard-and-mouse user can do until you revoke. That's
  the feature; the grant-time disclosure and panic hotkey are the
  mitigations, and granting to someone you don't trust isn't mitigable.
- **An adversary in your physical line of sight.** Yes, this is silly to
  say, but they can read your screen with their eyes.
