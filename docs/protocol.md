---
title: Network Protocol
nav_order: 6
permalink: /protocol/
has_children: true
---

# Network protocol
{: .no_toc }

1. TOC
{:toc}

This page explains how the protocol works and why it is shaped this way. The
normative definition — every MUST and MUST NOT, with stable requirement
identifiers and a machine-readable conformance suite behind them — is the
[Wire Protocol Specification]({{ site.baseurl }}{% link spec.md %}). Where the
two disagree, the specification wins.

Tailscreen uses **one port — `7447` — on both TCP and UDP**, and that's it.
All traffic rides over the tailnet's WireGuard tunnel, so anything you read
below is happening inside an authenticated, encrypted pipe. "Tailnet" rather
than "Tailscale" throughout: the protocol leans on the mesh for peer identity
and discovery as much as for encryption, and a self-hosted
[headscale]({{ site.baseurl }}{% link self-hosted.md %}) control plane supplies
all of it just as the hosted service does.

`7447` is a *provisional* default, not an IANA-registered assignment. Nothing
negotiates or discovers it, so peers on different numbers simply don't find
each other — which is why it reads as fixed in practice. It is still free to
move, and for that reason the literal lives once in the code, in
`NetworkConfig.tailscreenPort`.

| Channel        | Transport | Purpose                                                              |
| :------------- | :-------- | :------------------------------------------------------------------- |
| Video          | UDP/7447  | RTP — HEVC (RFC 7798) or H.264 (RFC 6184). Lossy on purpose.         |
| Audio          | UDP/7447  | RTP — Opus voice (PT 98) and system audio (PT 99).                   |
| Control        | UDP/7447  | Small control datagrams: HELLO family, PLI, NACK, receiver reports, FEC parity. |
| Annotations    | TCP/7447  | Length-framed JSON messages. Reliable on purpose.                    |
| Remote control | TCP/7447  | Request/grant/revoke + input events, on the same framed channel.     |
| Metadata       | TCP/7447  | Share name, resolution, request-to-share prompts.                    |
| Discovery      | —         | Read off the tailnet's own netmap, not probed. See below.            |

## Video — UDP RTP

NAL units packetized per RFC 6184 (H.264) and RFC 7798 (HEVC) on top of
RFC 3550 RTP.

Four things worth calling out:

**Two codecs, picked by the sharer, told to the viewer via the RTP
payload type.** The sharer tries HEVC first and falls back to H.264 if
VideoToolbox refuses (mostly Intel Macs without HW HEVC). The codec is
signalled on every packet by the payload type:

- `96` — H.264
- `97` — HEVC

The viewer demuxes from the payload type and configures the decoder on
the fly. There's no SDP, no handshake, no separate "codec announce"
message; the bytes on the wire are self-describing. HEVC is the default
because on screen content (flat regions, sharp edges, repeated text
glyphs) it's roughly 30% more efficient than H.264 at the same visual
quality — which matters on a bandwidth-constrained Wi-Fi link.

**Parameter sets go in-band, on every keyframe.** SPS+PPS for H.264;
VPS+SPS+PPS for HEVC. Most RTP H.264 implementations put parameter sets
in out-of-band SDP — we don't have one, and viewers can connect at any
time, so the parameter sets ship with every keyframe instead. Cost: a
few hundred bytes per keyframe. Benefit: a viewer that connects
mid-stream sees pixels in under a second, no handshake.

**Color rides in-band too.** The encoder writes the color primaries,
transfer function, matrix, and bit depth into the SPS VUI, and the viewer
reads them back onto the decoded buffers and its Metal layer — so wide
color needs no protocol change at all. By default the sharer tags
BT.709, or Display P3 when capturing a wide-gamut display. The sharer's
**Settings → Color** toggles opt into 10-bit HEVC Main 10 (BT.2020 PQ for
HDR), still gated on the display actually being capable — and on the
audience: viewers advertise a `tenBit` capability bit in their `HELLO`, and
because a sharer encodes once for everyone, the share holds at 8-bit while
any viewer that didn't advertise it is watching. One that joins mid-stream
latches a 10-bit share back down. A viewer whose decoder surprises it
after the fact can still send `PROFILE_NO` (below), which latches the same
way — a lighter fallback than dropping all the way to H.264.

**Keyframe-on-PLI.** The viewer sends a Picture Loss Indication when it
detects a gap in sequence numbers it can't recover from. The encoder
forces a keyframe in response. Combined with the periodic ~2-second
keyframe schedule, this means a transient loss costs you milliseconds of
artifacts, not seconds of green frames. UDP loss is fine — and where it's
cheap to repair, the NACK/FEC machinery below repairs it without a
keyframe at all.

## Audio — UDP RTP

Same socket, same RTP framing, separate payload types and a separate SSRC
space from video. Opus (royalty-free, software-only), mono, 48 kHz, one
20 ms frame (960 samples) per packet:

- `98` — voice (bidirectional; the sharer also relays each viewer's voice
  to the other viewers, byte-for-byte, after validating the packet's SSRC
  against the one the server assigned that viewer).
- `99` — system audio (sharer → viewers only; what the sharer's machine is
  playing). Viewers demux by payload type, exactly like video's 96/97.

SSRC allocation is deliberately partitioned: the sharer's voice owns SSRC
`0`, system audio owns the reserved SSRC `1`, and viewer-assigned SSRCs
start at `2`. The inbound gate on the sharer accepts only PT 98 from
viewers, which doubles as the anti-spoof rule for PT 99 — a viewer can't
inject fake "system audio". Old viewers reject PT 99 and silently drop
it, so system audio degrades to nothing on peers that predate it.

## Control — UDP, in-band

The viewer and sharer exchange small control datagrams over the same UDP
socket. Most are a single byte; the loss-recovery family carries short
binary payloads:

| Byte   | Message           | Direction       | Meaning                                                    |
| :----- | :---------------- | :-------------- | :--------------------------------------------------------- |
| `0x00` | `HELLO`           | viewer → sharer | Viewer is here; please send an IDR. Optionally extended with a capability byte (below). |
| `0x01` | `KEEPALIVE`       | viewer → sharer | Viewer is still here; keep me in the fan-out set.          |
| `0x02` | `BYE`             | viewer → sharer | Viewer is leaving; drop me from the fan-out.               |
| `0x03` | `PLI`             | viewer → sharer | Viewer lost something it can't recover; please send an IDR. |
| `0x04` | `HELLO_ACK`       | sharer → viewer | You're admitted; here's your SSRC (`[ssrc:4 BE]`). Extended with a server-caps byte for cap-aware viewers. |
| `0x05` | `SERVER_BYE`      | sharer → viewer | Share is over; tear down now instead of waiting out the idle timer. |
| `0x06` | `HELLO_PENDING`   | sharer → viewer | You're in the approval queue; show "waiting", not a black window. |
| `0x07` | `CODEC_NO`        | viewer → sharer | I can't decode this codec — the sharer latches the share to H.264. |
| `0x08` | `HELLO_DENY`      | sharer → viewer | The sharer declined (or blocked) you. Followed by `SERVER_BYE`. |
| `0x09` | `PROFILE_NO`      | viewer → sharer | I decode this codec but not its bit depth — latch to 8-bit HEVC. |
| `0x0A` | `NACK`            | viewer → sharer | Selective retransmission request (payload below).          |
| `0x0B` | `RECEIVER_REPORT` | viewer → sharer | ~1 Hz loss/jitter/RTT feedback (payload below).            |
| `0x0C` | `PING`            | sharer → viewer | ~1 Hz RTT probe, echoed back in the receiver report.       |
| `0x0D` | `FEC`             | sharer → viewer | XOR parity datagram for zero-RTT single-loss repair (payload below). |

How can these coexist with full RTP packets on the same port? Every real
RTP packet is V=2, which forces the leading byte into `0x80`-`0xBF`.
Control messages live in `0x00`-`0x7F`, so the first byte unambiguously
says which kind of datagram it is. No framing, no header, no port
multiplexing.

**Backward compatibility is one rule applied everywhere: unknown bytes
are ignored.** An old peer that doesn't know `HELLO_DENY` or `FEC` drops
the datagram and carries on; a new peer talking to an old one simply
never receives the new bytes. Every addition above was designed so that
the ignore-unknown rule alone produces sensible degraded behavior.

### Capability negotiation

A viewer that supports loss recovery sends an **extended HELLO** —
`[0x00][caps:1]` — where the caps bits are: bit 0 NACK, bit 1
receiver-report, bit 2 FEC. An old sharer reads byte 0 only and never
notices. A cap-aware sharer records the bits and replies with an
**extended HELLO_ACK**: `[0x04][ssrc:4][serverCaps:1]`, 6 bytes — but
*only* to viewers that advertised caps. A legacy viewer's HELLO_ACK
parser strictly requires 5 bytes and rejects the 6-byte form, which is
exactly the point: it never half-enters a mode it doesn't support. The
whole recovery matrix degrades cleanly in both directions, ending at
plain PLI.

`serverCaps` also carries two bits the viewer never sends back — sharer
capabilities the viewer uses to gate its own UI so it never offers an
interaction the sharer can't honour:

- **bit 3 `remoteControl`** — this build/platform can inject viewer input.
  The viewer offers Request Control only when set, so a non-injection
  sharer (a future Linux/Windows build) never receives a `.controlRequest`
  it would silently drop. Static capability: the sharer's runtime "Allow
  control requests" toggle and Accessibility grant still decline a live
  request with `controlRevoked`.
- **bit 4 `annotations`** — this sharer renders viewer annotations on its
  own overlay and relays them to other viewers. The viewer's annotation
  toolbar is disabled when absent, so it never draws local-only strokes
  that reach neither the sharer nor other viewers.

Both follow the same rule the loss-recovery caps do: absence degrades to
"feature off," and — pre-1.0 with no deployed peers — the bit is
authoritative, so a set bit is the only thing that lights up the UI.

The viewer's HELLO carries one bit of its own beyond the recovery three:

- **bit 5 `tenBit`** — this viewer can decode a 10-bit bitstream (HEVC
  Main 10). Unlike the recovery bits, which govern one link, this one
  governs the whole share: the sharer encodes once and fans the same
  packets out, so it drops to 8-bit for everyone as soon as a viewer
  without the bit is admitted. Absence is read as "can't" — a legacy
  viewer has no way to say otherwise, and the failure it prevents (a
  viewer whose decoder refuses every frame) is worse than the one it
  causes (two bits of colour depth nobody was promised).

Bits 0–5 are assigned; the rest are reserved, with an escape hatch to a
second caps byte specified in
[Growing the capability field]({{ site.baseurl }}{% link spec.md %}#54-growing-the-capability-field).

### NACK — selective retransmission (`0x0A`)

RTCP generic-NACK FCI semantics
([wire format]({{ site.baseurl }}{% link spec.md %}#91-nack)): the viewer
names the first missing sequence number and a bitmask of the 16 after it,
in *that viewer's* sequence space — every viewer gets its own rewritten
RTP header.

The sharer answers with byte-identical retransmissions from a bounded
send-side ring, under a per-viewer token budget capped at 25% of the
video bitrate. If the gap has already been evicted from the ring, or the
viewer is over budget, the sharer falls back to forcing a keyframe — so
NACK is strictly an optimization in front of the PLI path, never a
replacement for it. Pure packet *reordering* never triggers a NACK; the
viewer runs a deeper reorder window in NACK mode precisely so
retransmits have time to land.

### Receiver reports and pings (`0x0B`, `0x0C`)

The sharer pings each cap-aware viewer about once a second; the viewer
echoes the ping timestamp in its ~1 Hz receiver report
([wire format]({{ site.baseurl }}{% link spec.md %}#92-receiver-reports-and-rtt)).
That gives the sharer real per-viewer loss fraction, cumulative sequence
position, jitter, and RTT — the inputs to the congestion controller (see
[Architecture]({{ site.baseurl }}{% link architecture.md %})). The report's
trailing `fecRecovered` count exists only on FEC-negotiated links
(a tolerant decoder reads 0 from the legacy form): packets repaired by FEC count as
*received* in the loss fraction, so the bitrate controller reacts only to
loss the viewer actually suffered, while the sharer separately
reconstructs the raw link loss to steer the FEC overhead.

### FEC — XOR parity (`0x0D`)

One parity datagram per group of up to N consecutive media packets
(N adapts 10 → 7 → 5 as measured raw loss rises), enough to reconstruct
any *one* lost packet in the group — including the frame-ending marker
packet — with zero additional round-trips
([wire format]({{ site.baseurl }}{% link spec.md %}#93-fec--xor-parity)).

Design points that matter:

- Parity rides the control-byte plane, not an RTP payload type, so a
  *lost parity packet* opens no sequence gap — no NACK, no reported loss,
  just an uncovered group. Redundancy that can't cause noise.
- Each group's parity is interleaved immediately after that group's last
  media packet, never batched at the end of a frame — a multi-hundred-
  packet keyframe would otherwise evict early groups from the viewer's
  bounded buffer before their recovery data even hit the wire.
- The sharer only turns FEC on for viewers whose own path measures
  RTT > 150 ms *and* raw loss > 2 % (where a retransmit round-trip is
  genuinely expensive), compensates the encoder bitrate to N/(N+1) so
  video + parity still fits the congestion budget, and turns it off
  after two consecutive clean windows.
- The viewer arms its FEC machinery on the first parity datagram it
  actually receives — negotiation alone changes nothing, so a clean link
  pays no extra buffering — and hands multi-loss groups (beyond XOR's
  single-loss limit) to NACK as before.

## Annotations / control — TCP

Length-prefixed framing on top of TCP:

```
[type: 1 byte][len: 4 bytes, big-endian UInt32][payload: N bytes]
```

The message types on this channel:

| Type   | Message           | Direction       | Payload (JSON)                                  |
| :----- | :---------------- | :-------------- | :----------------------------------------------- |
| `0x03` | `annotation`      | viewer → sharer | An annotation op (stroke, undo, clear).          |
| `0x04` | `requestToShare`  | peer → peer     | "Please share your screen."                      |
| `0x05` | `shareResponse`   | receiver → requester | Accept/decline, sent back **on the same connection** the request arrived on. |
| `0x06` | `controlRequest`  | viewer → sharer | "Let me control your machine."                   |
| `0x07` | `controlGranted`  | sharer → viewer | You have control.                                |
| `0x08` | `controlRevoked`  | sharer → viewer | Control ended (`{reason}`).                      |
| `0x09` | `inputEvent`      | viewer → sharer | Mouse move/down/up/scroll, key down/up. Coordinates normalized `[0,1]` top-left; keys are **USB HID usage IDs** with a platform-neutral modifier set — no platform's native keycodes or flag bits ever ride the wire ([details]({{ site.baseurl }}{% link spec.md %}#122-input-events)). |
| `0x0A` | `controlReleased` | viewer → sharer | "I'm done controlling" — the sharer revokes so UI and gate clear in step. |

`0x00`–`0x02` are historical and stay reserved. Types `0x0A`–`0x0C` also
appear in the UDP control table above — that's fine, they're disjoint
spaces on disjoint transports. Unknown type bytes are skipped, which is
the entire backward-compatibility story on this channel too.

Two hard limits protect the parser: a single frame's declared length is
capped at **1 MiB** (a peer declaring more is treated as a corrupt stream
and disconnected — nobody gets to slow-stream a bogus 4 GiB frame into
the sharer's memory), and annotation/control ops are only honoured from
**admitted** viewers — a pending, denied, or blocked peer can open the
TCP connection but its ops go nowhere.

Yes, the payload is JSON. Yes, you could shave bytes with a binary
encoding. No, it doesn't matter — strokes and input events are tens of
bytes each, and the bandwidth budget for this channel is rounding error
compared to the video.

Why TCP for this and UDP for video? Because **dropping a stroke segment
(or a mouse-up) is visible and confusing; dropping a video frame is
invisible.** A circle drawn as two disconnected arcs reads as broken
software; a 16 ms frame stutter goes unnoticed. The transport choice
tracks the cost of loss.

## Metadata — TCP request/response

The metadata service listens on the same TCP/7447 socket and responds to a
few simple request types: "who are you?", "what's your resolution?", and
the request-to-share prompt.

Request-to-share got a real answer path: the response (`shareResponse`,
type `0x05`) travels back **on the same TCP connection the request
arrived on** — no dial-back, so the answer provably reaches the actual
requester and can't be spoofed to a third party. The requester holds the
connection open awaiting it; a timeout or EOF means "no answer", which is
also exactly what an older peer produces, so the addition is backward
compatible. On the receiving side, pending requests are deduplicated and
capped by the peer's **source IP** — not the hostname claimed in the
payload — so a flood can't stack banner rows or pin unbounded
connections. Accepting a request also pre-approves the requester's IP for
the share that follows, so they don't hit the viewer-approval gate a
second time.

This isn't its own port for a reason: opening a second port would mean a
second hole in any tailnet ACL and a second TCP probe in discovery. One
port, multiple channels, separated by the framing byte.

## Discovery

Discovery reads the tailnet, it doesn't probe it. Every Tailscreen
installation registers its tsnet node under a hostname starting
`tailscreen-`, so the IPN netmap already says which machines are Tailscreen
installations and which are online — no TCP or UDP probe adds anything.
Ephemeral viewer-only nodes register under `tailscreen-client-` and are
excluded, so a transient viewer never shows up as something you can connect
to.

Share *status* is the one thing the netmap can't tell you, and that's a
separate, lazy query: the metadata pair above (`0x0B`/`0x0C`), dialled
concurrently across online peers only when the menu opens, on a manual
refresh, or when the "only screens being shared" filter turns on. Every
failure — timeout, EOF, an older peer dropping the unknown byte — reads as
*status unknown*, never as "not sharing".

## Guests — the same protocol over a token-bootstrapped tunnel

Everything on this page also runs over the **share-by-token guest tunnel**
("Share via Link"): a per-link ephemeral WireGuard pair whose bootstrap —
the sharer's public key plus relay details — travels in an opaque `tc…`
token instead of a tailnet's netmap. Nothing on the wire inside the tunnel
changes: both channels of `7447`, the same bytes, the same capability
negotiation, the same loss-recovery ladder. What the tunnel can't supply
is peer enumeration — the token *is* the rendezvous, so discovery is
simply inapplicable — and the sharer compensates at the admission layer:
a guest's stable identifier is its WireGuard node key, approval is
mandatory on every join, and a deny evicts that key at the tunnel for the
life of the link. The full accounting is
[Appendix D of the specification]({{ site.baseurl }}{% link spec.md %}#appendix-d-transport-bootstrap-via-connection-token-guest-mode)
(informative — it adds no wire values and changes no requirements) and the
[security model]({{ site.baseurl }}{% link security.md %}).

## Changing the protocol

Every wire constant above is pinned by a registry test
(`WireByteRegistryTests`), and every parser on this page runs through a
deterministic seeded fuzz harness in CI. The rules they all obey are
normative in the
[Wire Protocol Specification]({{ site.baseurl }}{% link spec.md %}), pinned
by the language-neutral vectors under `conformance/`. A change to a wire
value touches three things in one commit: the registry test, the
specification's [registry appendix]({{ site.baseurl }}{% link spec.md %}#appendix-a-wire-value-registry),
and a vector — and a shipped byte is never renumbered; deployed peers
would break.
