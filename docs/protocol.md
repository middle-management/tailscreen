---
title: Network Protocol
nav_order: 5
permalink: /protocol/
---

# Network protocol
{: .no_toc }

1. TOC
{:toc}

Tailscreen uses **one port — `7447` — on both TCP and UDP**, and that's it.
All traffic rides over Tailscale's WireGuard tunnel, so anything you read
below is happening inside an authenticated, encrypted pipe.

| Channel        | Transport | Purpose                                                              |
| :------------- | :-------- | :------------------------------------------------------------------- |
| Video          | UDP/7447  | RTP — HEVC (RFC 7798) or H.264 (RFC 6184). Lossy on purpose.         |
| Audio          | UDP/7447  | RTP — Opus voice (PT 98) and system audio (PT 99).                   |
| Control        | UDP/7447  | Small control datagrams: HELLO family, PLI, NACK, receiver reports, FEC parity. |
| Annotations    | TCP/7447  | Length-framed JSON messages. Reliable on purpose.                    |
| Remote control | TCP/7447  | Request/grant/revoke + input events, on the same framed channel.     |
| Metadata       | TCP/7447  | Share name, resolution, request-to-share prompts.                    |
| Discovery      | TCP/7447  | Probe across the tailnet to find Tailscreen peers.                   |

Planning to make `7447` configurable? It's hardcoded across the discovery,
server, client, and metadata paths — search for `7447` and update every
occurrence, or discovery quietly finds nothing.

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
BT.709, or Display P3 when capturing a wide-gamut display. Setting
`TAILSCREEN_ENABLE_10BIT` / `TAILSCREEN_ENABLE_HDR` on the sharer opts
into 10-bit HEVC Main 10 (BT.2020 PQ for HDR), still gated on the display
actually being capable. A viewer whose hardware decodes HEVC but not
10-bit sends `PROFILE_NO` (below) and the share latches back to 8-bit —
a lighter fallback than dropping all the way to H.264.

**Keyframe-on-PLI.** The viewer sends a Picture Loss Indication when it
detects a gap in sequence numbers it can't recover from. The encoder
forces a keyframe in response. Combined with the periodic ~2-second
keyframe schedule, this means a transient loss costs you milliseconds of
artifacts, not seconds of green frames. UDP loss is fine — and where it's
cheap to repair, the NACK/FEC machinery below repairs it without a
keyframe at all.

## Audio — UDP RTP

Same socket, same RTP framing, separate payload types and a separate SSRC
space from video. Opus (royalty-free, software-only — it replaced the
original AAC-LC path), mono, 48 kHz, one 20 ms frame (960 samples) per
packet:

- `98` — voice (bidirectional; the sharer also relays each viewer's voice
  to the other viewers, byte-for-byte, after validating the packet's SSRC
  against the one the server assigned that viewer).
- `99` — system audio (sharer → viewers only; what the sharer's Mac is
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

**Reserved / future caps.** The `caps` byte is a single `UInt8` per
direction; bits 0–4 are assigned, leaving room but not unlimited room.
Candidates deliberately *not* yet spent:

- **Video-codec caps** (viewer→sharer "I decode HEVC" / "I decode 10-bit").
  The weakest candidate, because codec is *already* negotiated — just not
  in HELLO. It's self-describing on every packet (payload type 96/97),
  the parameter sets ride every keyframe, and the `CODEC_NO` / `PROFILE_NO`
  fallbacks are keyframe-latched: an incompatible viewer signals, the
  sharer re-inits the encoder, and the switch lands at the next keyframe
  (~1–2 s). A HELLO cap would only save the *initial* `CODEC_NO`
  round-trip for a single incompatible viewer — a time-to-first-frame
  delay at startup, not a mid-stream glitch — and even that is diluted by
  the encode-once-fan-out rule (the first non-HEVC viewer latches everyone
  to H.264 anyway). The existing keyframe-granular mechanism already
  converges on its own; a cap is pure polish.
- **System-audio cap** (viewer→sharer "I play PT 99") would let the sharer
  skip system-audio fan-out to viewers that would drop it — a bandwidth
  optimization, not a UX one.
- **~~Opus~~ — no cap needed (decision: Opus-only).** Opus was the obvious
  "must-negotiate" future codec, but the pre-1.0 decision is to *replace*
  AAC with Opus rather than negotiate between them (see
  `docs/porting-plan.md` #6). Opus has no support gap on any platform, so
  with no deployed AAC-only peers there's nothing to negotiate — one
  audio codec, distinguished on the wire by its payload type like the
  existing 98/99, no capability bit.

**Extending the caps field.** If the 8 bits ever fill, reserve the top bit
as an "extended caps follow" flag: a peer that sets it appends a second
caps byte, and a peer that understands the flag reads it. Old peers that
don't set/understand the flag stay single-byte — the same
ignore-unknown degradation, applied to the caps field itself. So the
budget is a soft limit, not a hard one; we just haven't needed the second
byte yet.

### NACK — selective retransmission (`0x0A`)

`[0x0A][count:1][(pid:2 BE, blp:2 BE) × count]`, ≤ 16 entries — RTCP
generic-NACK FCI semantics: `pid` is the first missing sequence number
(in *that viewer's* sequence space; every viewer gets its own rewritten
RTP header), `blp` a bitmask of the 16 sequence numbers after it.

The sharer answers with byte-identical retransmissions from a bounded
send-side ring, under a per-viewer token budget capped at 25% of the
video bitrate. If the gap has already been evicted from the ring, or the
viewer is over budget, the sharer falls back to forcing a keyframe — so
NACK is strictly an optimization in front of the PLI path, never a
replacement for it. Pure packet *reordering* never triggers a NACK; the
viewer runs a deeper reorder window in NACK mode precisely so
retransmits have time to land.

### Receiver reports and pings (`0x0B`, `0x0C`)

The sharer pings each cap-aware viewer about once a second
(`[0x0C][serverUptimeNs:8]`); the viewer echoes that timestamp in its
~1 Hz receiver report:

```
[0x0B][fracLostQ8:1][extHighestSeq:4][jitterTicks:4]
      [lastPingTs:8][delaySincePingMs:2]           — 20 bytes
      [fecRecovered:2 BE]                          — optional, 22-byte form
```

That gives the sharer real per-viewer loss fraction, cumulative sequence
position, jitter, and RTT — the inputs to the congestion controller (see
[Architecture]({% link architecture.md %})). The trailing `fecRecovered`
count exists only on FEC-negotiated links (a tolerant decoder reads 0
from the legacy 20-byte form): packets repaired by FEC count as
*received* in the loss fraction, so the bitrate controller reacts only to
loss the viewer actually suffered, while the sharer separately
reconstructs the raw link loss to steer the FEC overhead.

### FEC — XOR parity (`0x0D`)

`[0x0D][baseSeq:2 BE][count:1][xor body]` — one parity datagram per group
of up to N consecutive media packets (N adapts 10 → 7 → 5 as measured
raw loss rises; `count` is the actual group size, 2–16, always
contiguous). The body is the XOR across the group of
`[len:2 BE][byte1][timestamp:4][payload…]`, zero-padded to the longest
member — enough to reconstruct any *one* lost packet in the group,
including the frame-ending marker packet, with zero additional
round-trips.

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
| `0x06` | `controlRequest`  | viewer → sharer | "Let me control your Mac."                       |
| `0x07` | `controlGranted`  | sharer → viewer | You have control.                                |
| `0x08` | `controlRevoked`  | sharer → viewer | Control ended (`{reason}`).                      |
| `0x09` | `inputEvent`      | viewer → sharer | Mouse move/down/up/scroll (left/right/middle), key down/up. Coordinates normalized `[0,1]` top-left, same convention as annotations. Keys are **USB HID keyboard-page usage IDs** and modifiers a five-bit platform-neutral set (shift/control/alt/meta/capsLock) — no platform's native keycodes or flag bits ever ride the wire; each endpoint translates (macOS: `MacKeyCodeMapping`). Button/scroll events carry the modifier snapshot too, so modified clicks work. |
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

## Discovery probe

Discovery enumerates peers from the local tsnet LocalAPI, then opens
TCP/7447 to each peer in parallel with a short timeout. Peers that accept
and reply with the Tailscreen handshake show up in **Browse Shares**.
Peers that don't, don't.

The probe is parallel because tailnets get big, and a serial probe of 50
peers with a 500ms timeout each is 25 seconds of staring at a spinner.
Parallel, it's 500ms total.

## Changing the protocol

Every wire constant above — TCP types, UDP control bytes, capability
bits, RTP payload types, reserved SSRCs — is pinned by a registry test
(`WireByteRegistryTests`) that asserts exact values, exhaustiveness, and
per-channel uniqueness, and every parser on this page is run through a
deterministic seeded fuzz harness in CI. If you add a wire byte, add its
registry row in the same commit; if you renumber a shipped one, the
registry will name you, and deployed peers will break. Don't.
