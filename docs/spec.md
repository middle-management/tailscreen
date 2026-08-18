---
title: Wire Protocol Specification
parent: Network Protocol
nav_order: 1
permalink: /protocol/spec/
---

# Tailscreen wire protocol specification
{: .no_toc }

Version 1 · normative
{: .fs-5 .fw-300 }

1. TOC
{:toc}

---

## 1. Introduction

Tailscreen is a peer-to-peer screen-sharing protocol. One peer — the
**sharer** — captures a display, window, or application and streams it to
one or more **viewers**, who may in turn send back voice, annotations, and
(with consent) input events.

This document is the normative definition of what goes on the wire. The
companion page [Network Protocol]({{ site.baseurl }}{% link protocol.md %})
explains *why* the protocol looks like this; where the two disagree, this
document wins.

Every numbered requirement below carries a stable identifier of the form
`TS-AREA-NNN`. Identifiers are permanent: a requirement that is withdrawn
keeps its number and is marked obsolete rather than being reused. The
machine-readable conformance vectors in `conformance/vectors/` cite these
identifiers, and [§17](#17-conformance) describes how to run them.

### 1.1 Requirements language

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL
NOT**, **SHOULD**, **SHOULD NOT**, **RECOMMENDED**, **MAY**, and
**OPTIONAL** in this document are to be interpreted as described in
[RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) and
[RFC 8174](https://www.rfc-editor.org/rfc/rfc8174) when, and only when,
they appear in all capitals.

### 1.2 Terminology

| Term | Meaning |
| :--- | :------ |
| **sharer** | The peer that captures and transmits media. Exactly one per session. |
| **viewer** | A peer that receives media from a sharer. Zero or more per session. |
| **peer** | Either role. Every Tailscreen installation can act as both, at different times. |
| **admitted viewer** | A viewer the sharer's admission gate has accepted ([§6](#6-viewer-admission)). |
| **session** | One sharer's share, from first capture frame to `SERVER_BYE`. |
| **implementation** | Any program speaking this protocol. |
| **tailnet** | The WireGuard mesh the peers sit on: nodes coordinated by a control plane that authenticates them, gives each a stable identity, and tells each node which peers exist and whether they are reachable. |
| **control plane** | The coordination server providing that. Tailscale's hosted service and [headscale](https://github.com/juanfont/headscale) are both implementations of it; this protocol depends on the tailnet's properties, never on which one is in use. |

### 1.3 Notation and conventions

- **TS-GEN-001**: All multi-byte integers on the wire MUST be encoded in
  network byte order (big-endian), unless a field is explicitly defined
  otherwise. No field in this specification is little-endian.
- **TS-GEN-002**: All byte offsets in this document are zero-based from the
  first byte of the datagram or frame being described.
- Field layouts are written `[name:width]`, width in bytes; `N` means
  variable. `[x:2 BE]` is a two-byte big-endian integer. Hexadecimal byte
  values are written `0x00`.
- Sequence-number and timestamp arithmetic is modular. **TS-GEN-003**:
  Implementations MUST perform RTP sequence-number comparison and
  arithmetic modulo 2^16 and RTP timestamp arithmetic modulo 2^32, wrapping
  rather than saturating or trapping.
- **TS-GEN-004**: An implementation MUST NOT assume that a peer runs the
  same version, platform, or feature set as itself. Every extension
  mechanism in this document ([§5](#5-capability-negotiation),
  [§15](#15-versioning-and-extensibility)) exists so that unknown input can
  be ignored rather than treated as an error.

---

## 2. Transport

- **TS-GEN-010**: The default port is **7447**, for both TCP and UDP. An
  implementation MUST listen and dial there unless explicitly configured
  otherwise, and MUST use the same port number for both transports.
- **TS-GEN-015**: There is no port negotiation. A deployment that moves off
  the default MUST configure the same number at every peer out of band;
  a peer cannot discover another peer's port.
- **TS-GEN-016**: 7447 is **not registered with IANA**. It is a provisional
  default and MAY change — up to and including whatever number a future
  registration assigns — so an implementation MUST read the port from a
  single configuration point rather than embedding the literal at each
  listen, dial and probe site. In this repository that point is
  `NetworkConfig.tailscreenPort`; a bare `7447` written anywhere else is a
  defect. Peers running different defaults do not interoperate, which is the
  cost a renumbering would carry and the reason it has not happened.
- **TS-GEN-011**: All traffic MUST be carried inside a tailnet
  ([§2.1](#21-the-tailnet)). The protocol defines no transport-level
  authentication, encryption, or integrity protection of its own, and
  implementations MUST NOT be deployed on an unprotected network path.
- **TS-GEN-012**: A sharer MUST listen on UDP/7447 for control datagrams and
  MUST send media to the source address and port from which it received an
  admitted viewer's `HELLO`.
- **TS-GEN-013**: A peer that can be asked to share (§13) MUST accept TCP
  connections on port 7447 for as long as its node is up, not only while a
  share is running. A peer that only ever views MAY omit the listener.
- **TS-GEN-014**: A sharer MUST NOT require more than one TCP connection per
  viewer, and MUST tolerate a viewer that opens the TCP channel at any time
  relative to its `HELLO`, including never.

### 2.1 The tailnet

This protocol is not merely tunnelled — it is *built on* a tailnet, and leans
on it for four distinct things. Naming them is what lets an implementation
know which substrates it may run on.

- **TS-GEN-017**: The tailnet MUST provide all four of:
  1. **Authentication** of every peer.
  2. **Encryption and integrity protection** of traffic between peers.
  3. **A stable per-node identifier** the local node can resolve from its own
     view, without trusting anything the remote peer claims. Viewer admission
     is keyed on it (TS-ADM-006, TS-SEC-004).
  4. **Peer enumeration and liveness** — a node can learn which peers exist
     and which are reachable, without probing. Discovery is built on it
     ([§14](#14-discovery)).
- **TS-GEN-018**: An implementation MUST NOT require a particular control
  plane. Tailscale's hosted service and headscale both satisfy TS-GEN-017 and
  are both supported; selecting one is deployment configuration, not
  protocol. In this repository it is the `TAILSCREEN_TS_CONTROL_URL`
  environment variable, and the end-to-end harness runs against headscale.
- **TS-GEN-019**: A deployment MUST NOT substitute a transport lacking any of
  TS-GEN-017's four properties. This is a narrower allowance than "any
  encrypted tunnel", deliberately: a plain WireGuard tunnel supplies the
  first two properties and neither of the last two, so viewer admission would
  have no identity to key on and discovery would have nothing to enumerate.
  Those requirements would not merely degrade — they would be
  unimplementable.

The channels multiplexed onto these two sockets are:

| Channel | Transport | Section |
| :------ | :-------- | :------ |
| Video | UDP/7447, RTP | [§7](#7-video) |
| Audio (voice, system audio) | UDP/7447, RTP | [§8](#8-audio) |
| Session control, loss recovery | UDP/7447, non-RTP datagrams | [§4](#4-udp-control-plane), [§9](#9-loss-recovery) |
| Annotations | TCP/7447, framed | [§11](#11-annotations) |
| Remote control | TCP/7447, framed | [§12](#12-remote-control) |
| Metadata, request-to-share | TCP/7447, framed | [§13](#13-metadata-and-request-to-share) |

---

## 3. Datagram demultiplexing

The UDP socket carries both RTP packets and control datagrams. They are
distinguished by the first byte alone; there is no shim header, no framing,
and no separate port.

Every RTP packet defined by this specification has version 2 and no padding,
so byte 0 is in the range `0x80`–`0xBF`.

- **TS-GEN-020**: A receiver MUST classify an inbound UDP datagram by its
  first byte: if `(byte0 & 0xC0) == 0x80` the datagram MUST be processed as
  RTP ([§7](#7-video), [§8](#8-audio)); otherwise it MUST be processed as a
  control datagram ([§4](#4-udp-control-plane)).
- **TS-GEN-021**: A sender MUST NOT assign a control message a first byte
  outside the range `0x00`–`0x7F`.
- **TS-GEN-022**: A receiver MUST silently discard an empty (zero-length)
  UDP datagram.
- **TS-GEN-023**: An implementation MUST emit RTP packets with version 2,
  padding 0, extension 0, and CSRC count 0 — that is, byte 0 equal to
  `0x80`.

---

## 4. UDP control plane

A control datagram begins with a one-byte message type. Some types carry a
fixed or variable payload; the rest are exactly one byte long.

### 4.1 Control message registry

| Byte | Name | Direction | Length | Payload |
| :--- | :--- | :-------- | :----- | :------ |
| `0x00` | `HELLO` | viewer → sharer | 1 or 2 | optional `[caps:1]` |
| `0x01` | `KEEPALIVE` | viewer → sharer | 1 | — |
| `0x02` | `BYE` | viewer → sharer | 1 | — |
| `0x03` | `PLI` | viewer → sharer | 1 | — |
| `0x04` | `HELLO_ACK` | sharer → viewer | 5 or 6 | `[ssrc:4 BE]` + optional `[caps:1]` |
| `0x05` | `SERVER_BYE` | sharer → viewer | 1 | — |
| `0x06` | `HELLO_PENDING` | sharer → viewer | 1 | — |
| `0x07` | `CODEC_NO` | viewer → sharer | 1 | — |
| `0x08` | `HELLO_DENY` | sharer → viewer | 1 | — |
| `0x09` | `PROFILE_NO` | viewer → sharer | 1 | — |
| `0x0A` | `NACK` | viewer → sharer | 2 + 4·k | `[count:1][(pid:2 BE)(blp:2 BE)]×k` |
| `0x0B` | `RECEIVER_REPORT` | viewer → sharer | 20, 22 or 24 | see [§9.2](#92-receiver-reports-and-rtt) |
| `0x0C` | `PING` | sharer → viewer | 9 | `[serverUptimeNs:8 BE]` |
| `0x0D` | `FEC` | sharer → viewer | 4 + N | see [§9.3](#93-fec-xor-parity) |

- **TS-CTL-001**: An implementation MUST encode each control message with
  the byte value in the table above. These values are permanent and MUST NOT
  be renumbered.
- **TS-CTL-002**: A receiver MUST silently discard a control datagram whose
  first byte it does not recognise. It MUST NOT close the session, reply
  with an error, or treat the datagram as media.
- **TS-CTL-003**: A receiver MUST silently discard a control datagram that
  is shorter than the minimum length defined for its type.
- **TS-CTL-004**: A receiver MUST accept a control datagram that is *longer*
  than the length defined for its type, processing the fields it
  understands and ignoring the trailing bytes, except where a stricter rule
  is stated (see TS-CAP-004).
- **TS-CTL-005**: A sharer MUST ignore `PING` (`0x0C`) and `FEC` (`0x0D`)
  received from a viewer, and a viewer MUST ignore `HELLO`, `KEEPALIVE`,
  `BYE`, `PLI`, `CODEC_NO`, `PROFILE_NO`, `NACK`, and `RECEIVER_REPORT`
  received from a sharer. Direction is part of each message's definition.

### 4.2 Session establishment

- **TS-CTL-010**: A viewer MUST send `HELLO` to begin a session and MUST NOT
  expect media before it does.
- **TS-CTL-011**: A viewer that has sent `HELLO` and received neither
  `HELLO_ACK`, `HELLO_PENDING`, nor `HELLO_DENY` SHOULD retransmit `HELLO`
  periodically until one arrives or the user abandons the attempt.
- **TS-CTL-012**: On admitting a viewer, a sharer MUST reply with
  `HELLO_ACK` carrying the SSRC it has allocated to that viewer
  ([§8.2](#82-ssrc-allocation)), and MUST transmit a keyframe as soon as one
  can be produced.
- **TS-CTL-013**: A sharer MUST allocate a distinct SSRC to each
  concurrently admitted viewer.
- **TS-CTL-014**: A viewer MUST use the SSRC it received in `HELLO_ACK` as
  the SSRC of every RTP packet it sends, for the lifetime of the session.
- **TS-CTL-015**: A viewer MUST send `KEEPALIVE` at least once every
  500 ms while it wishes to remain in the session.
- **TS-CTL-016**: A sharer MUST drop a viewer that has sent no datagram for
  15 s, and MUST free that viewer's SSRC for reallocation.
- **TS-CTL-017**: A viewer MUST tear down a session after 15 s with no
  datagram of any kind from the sharer. The two timeouts are equal by
  design; an implementation MUST NOT set them independently.
- **TS-CTL-018**: A viewer that leaves voluntarily SHOULD send `BYE`. A
  sharer MUST treat `BYE` as an immediate drop and MUST NOT wait out the
  idle timeout.
- **TS-CTL-019**: A sharer that stops sharing MUST send `SERVER_BYE` to
  every admitted and pending viewer before releasing the session.
- **TS-CTL-020**: A viewer MUST treat `SERVER_BYE` as the end of the
  session and MUST NOT continue sending media, `KEEPALIVE`, or recovery
  feedback afterwards without a fresh `HELLO`.

### 4.3 Keyframe requests and codec fallback

- **TS-CTL-030**: A viewer that has lost media it cannot recover MUST be
  able to request a keyframe by sending `PLI`, and a sharer MUST honour
  `PLI` from an admitted viewer by producing a keyframe as soon as its
  encoder permits.
- **TS-CTL-031**: A sharer SHOULD rate-limit its response to `PLI` so that a
  burst of requests does not produce a burst of keyframes.
- **TS-CTL-032**: A viewer that cannot decode the codec it is receiving MUST
  send `CODEC_NO`, and MUST NOT simply render nothing.
- **TS-CTL-033**: On receiving `CODEC_NO` from an admitted viewer while
  encoding HEVC, a sharer MUST switch the share to H.264 and MUST emit a
  keyframe at the switch. The switch applies to all viewers of that share.
- **TS-CTL-034**: A viewer that can decode the codec but not its
  profile or bit depth MUST send `PROFILE_NO` rather than `CODEC_NO`.
- **TS-CTL-035**: On receiving `PROFILE_NO` while encoding 10-bit HEVC, a
  sharer MUST latch the share to 8-bit and MUST emit a keyframe at the
  switch. It MUST NOT drop to H.264 for `PROFILE_NO` alone.
- **TS-CTL-036**: A sharer MUST NOT interpret `CODEC_NO` or `PROFILE_NO`
  from an unadmitted peer.

---

## 5. Capability negotiation

Optional features are negotiated in one round trip, inside `HELLO` and
`HELLO_ACK`. There is no SDP, no offer/answer, and no out-of-band
description.

### 5.1 The capability byte

Both directions use a single `UInt8` bit field.

| Bit | Mask | Name | Sent by | Meaning |
| :-- | :--- | :--- | :------ | :------ |
| 0 | `0x01` | `nack` | both | Peer implements selective retransmission ([§9.1](#91-nack)). |
| 1 | `0x02` | `receiverReport` | both | Peer implements receiver reports and RTT pings ([§9.2](#92-receiver-reports-and-rtt)). |
| 2 | `0x04` | `fec` | both | Peer implements XOR parity ([§9.3](#93-fec-xor-parity)). |
| 3 | `0x08` | `remoteControl` | sharer only | This sharer can inject viewer input ([§12](#12-remote-control)). |
| 4 | `0x10` | `annotations` | sharer only | This sharer renders and relays viewer annotations ([§11](#11-annotations)). |
| 5–7 | `0xE0` | — | — | Reserved. |

- **TS-CAP-001**: A sender MUST set reserved capability bits to zero.
- **TS-CAP-002**: A receiver MUST ignore capability bits it does not
  understand, and MUST NOT reject the message that carried them.
- **TS-CAP-003**: A viewer MUST NOT set bits 3 or 4 in its `HELLO`, and a
  sharer MUST ignore those bits if a viewer sets them.

### 5.2 Extended HELLO and HELLO_ACK

A viewer with no capabilities sends the one-byte `HELLO`. A viewer with
capabilities sends the two-byte form:

```
[0x00][caps:1]
```

A sharer answers with either the plain five-byte acknowledgement or the
extended six-byte form:

```
[0x04][ssrc:4 BE]                 — plain, 5 bytes
[0x04][ssrc:4 BE][serverCaps:1]   — extended, 6 bytes
```

- **TS-CAP-004**: A sharer MUST send the extended six-byte `HELLO_ACK`
  **only** to a viewer whose `HELLO` carried a capability byte, and MUST
  send the plain five-byte form to every other viewer. An implementation
  that predates capability negotiation accepts only the five-byte form, and
  sending it six bytes would leave it with no session at all.
- **TS-CAP-005**: A capability-aware viewer MUST accept both the five-byte
  and six-byte forms, treating the absent capability byte as no
  capabilities.
- **TS-CAP-006**: A sharer MUST treat a one-byte `HELLO` as advertising no
  capabilities, and MUST NOT infer capabilities from any other signal.
- **TS-CAP-007**: A feature governed by a capability bit MUST be used on a
  given link only if **both** peers advertised it. A peer MUST NOT send
  `NACK`, `RECEIVER_REPORT`, or `FEC` on a link where the corresponding bit
  was not advertised in both directions.
- **TS-CAP-008**: A viewer MUST NOT offer the user an action gated on a
  sharer-only capability bit that the sharer did not advertise. In
  particular it MUST NOT send `controlRequest` to a sharer that did not
  advertise `remoteControl`, and it MUST NOT accept local annotation input
  for a sharer that did not advertise `annotations`.
- **TS-CAP-009**: A sharer MUST advertise `remoteControl` if and only if the
  build and platform can inject input at all. The bit describes static
  capability; a runtime refusal is signalled with `controlRevoked`
  ([§12](#12-remote-control)) instead.

### 5.3 Growing the capability field

- **TS-CAP-010**: A future revision that needs more than eight capability
  bits MUST reserve bit 7 as an "extended capabilities follow" flag and
  append a second byte after it, rather than redefining bits 0–6. A peer
  that does not understand the flag MUST continue to read only the first
  byte, which TS-CAP-002 already permits.

---

## 6. Viewer admission

- **TS-ADM-001**: A sharer MUST apply an admission decision to every `HELLO`
  before adding the viewer to the media fan-out set, and MUST NOT send media
  to a viewer that has not been admitted.
- **TS-ADM-002**: A sharer whose policy requires the user's approval MUST
  reply `HELLO_PENDING` and MUST repeat `HELLO_PENDING` in response to each
  `HELLO` retransmission while the decision is outstanding.
- **TS-ADM-003**: A sharer MUST prune a viewer that has been pending for
  longer than 60 s.
- **TS-ADM-004**: A sharer that declines a viewer MUST send `HELLO_DENY`
  followed by `SERVER_BYE`. Sending `SERVER_BYE` alone is permitted only for
  implementations that do not distinguish decline from stop, and is
  NOT RECOMMENDED.
- **TS-ADM-005**: A viewer MUST distinguish `HELLO_DENY` from `SERVER_BYE`
  in what it reports to the user when it implements both.
- **TS-ADM-006**: A sharer that maintains a persistent per-peer allow/deny
  store MUST key it on the peer's stable node identifier (TS-GEN-017.3) as
  resolved from the sharer's own view of the tailnet, and MUST NOT key it on
  any identifier supplied by the peer in a wire payload. Under both Tailscale
  and headscale that identifier is the node's StableNodeID.
- **TS-ADM-007**: A remembered deny MUST outrank an otherwise permissive
  admission policy.
- **TS-ADM-008**: After expelling a viewer, a sharer MUST answer that
  address's `KEEPALIVE` with denial rather than re-admitting it, for at
  least 30 s. Only a fresh `HELLO` clears the quiet window.
- **TS-ADM-009**: A sharer MUST revoke any remote-control grant held by a
  viewer at the moment that viewer leaves the fan-out set, by any path
  (`BYE`, idle timeout, expulsion, TCP close, or end of share).

---

## 7. Video

Video is RTP ([RFC 3550](https://www.rfc-editor.org/rfc/rfc3550)) carrying
H.264 ([RFC 6184](https://www.rfc-editor.org/rfc/rfc6184)) or HEVC
([RFC 7798](https://www.rfc-editor.org/rfc/rfc7798)) payloads.

### 7.1 RTP header

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|V=2|P|X|  CC   |M|     PT      |       sequence number         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           timestamp                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                             SSRC                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

- **TS-VID-001**: A sender MUST emit a 12-byte fixed RTP header with V=2,
  P=0, X=0, CC=0.
- **TS-VID-002**: A receiver MUST reject a datagram whose RTP version is not
  2.
- **TS-VID-003**: A receiver MUST compute the payload offset as
  `12 + 4·CC`, and, when X=1, MUST additionally skip the four-byte extension
  header and the `length` 32-bit words it declares. A receiver MUST reject a
  packet that is too short for the offset it computes.
- **TS-VID-004**: A sender MUST increment the sequence number by exactly one
  for each RTP packet emitted on a given SSRC, including retransmissions'
  originals, and MUST NOT skip values.
- **TS-VID-005**: All RTP packets belonging to one access unit MUST carry
  the same timestamp.
- **TS-VID-006**: A sender MUST set the marker bit on the last packet of an
  access unit and MUST clear it on every other video packet.
- **TS-VID-007**: The video RTP clock rate is 90 000 Hz.
- **TS-VID-008**: A sender MUST NOT set the padding (P) bit. Tailscreen
  defines no use for RTP padding, and a receiver is NOT required to strip it:
  a peer that sets P will have its padding bytes delivered to the
  depacketizer as though they were payload. A receiver MAY reject a packet
  with P set; it MUST NOT trust the trailing padding-length byte to bound a
  read.

### 7.2 Payload types and codec signalling

| Payload type | Media |
| :--- | :--- |
| 96 | H.264 |
| 97 | HEVC |
| 98 | Opus voice |
| 99 | Opus system audio |

- **TS-VID-010**: A sender MUST signal the video codec solely through the
  RTP payload type: 96 for H.264, 97 for HEVC.
- **TS-VID-011**: A receiver MUST determine the codec from the payload type
  of each packet and MUST NOT require any out-of-band codec announcement.
- **TS-VID-012**: A receiver MUST tolerate the payload type changing
  mid-session, reconfiguring its decoder at the next keyframe.
- **TS-VID-013**: A receiver MUST discard a video packet whose payload type
  is neither 96 nor 97.

### 7.3 Parameter sets and colour

- **TS-VID-020**: A sender MUST transmit the active parameter sets in band,
  immediately preceding every keyframe: SPS and PPS for H.264; VPS, SPS and
  PPS for HEVC. It MUST NOT rely on a receiver having seen an earlier
  parameter set.
- **TS-VID-021**: A receiver MUST be able to start decoding from any
  keyframe without prior state.
- **TS-VID-022**: A sender MUST describe colour primaries, transfer
  characteristics, matrix coefficients and bit depth in the SPS VUI, and
  MUST NOT signal them in any Tailscreen-specific message.
- **TS-VID-023**: A receiver SHOULD apply the signalled colour description
  to the decoded frames and its display surface, and MUST render the stream
  regardless if it cannot.

### 7.4 Packetization

- **TS-VID-030**: A sender MUST NOT emit an RTP payload larger than 1100
  bytes, excluding the RTP header.
- **TS-VID-031**: A NAL unit that fits within the payload limit MUST be sent
  as a single-NAL-unit packet whose payload is exactly the NAL unit,
  including its NAL header.
- **TS-VID-032**: An H.264 NAL unit that exceeds the payload limit MUST be
  fragmented with FU-A ([RFC 6184 §5.8](https://www.rfc-editor.org/rfc/rfc6184#section-5.8)):
  each fragment carries `[FU indicator:1][FU header:1][fragment bytes]`,
  where the FU indicator is `(nalHeader & 0x60) | 28`, and the FU header is
  `(nalHeader & 0x1F)` with bit 7 set on the first fragment and bit 6 set on
  the last.
- **TS-VID-033**: An HEVC NAL unit that exceeds the payload limit MUST be
  fragmented with the FU payload structure
  ([RFC 7798 §4.4.3](https://www.rfc-editor.org/rfc/rfc7798#section-4.4.3)):
  each fragment carries `[PayloadHdr:2][FU header:1][fragment bytes]`, where
  the PayloadHdr preserves the original F bit, LayerId and TID and sets Type
  to 49, and the FU header carries the original six-bit NAL type with bit 7
  set on the first fragment and bit 6 set on the last.
- **TS-VID-034**: A sender MUST NOT use aggregation packets (STAP-A, AP) or
  any other payload structure not listed here.
- **TS-VID-035**: A receiver MUST reassemble fragments by sequence number
  and MUST discard an access unit it cannot reassemble completely.
- **TS-VID-036**: An HEVC sender MUST discard a NAL unit shorter than two
  bytes rather than emitting it, since it cannot carry a valid HEVC NAL
  header.

### 7.5 Reordering and loss

- **TS-VID-040**: A receiver MUST tolerate reordering and duplication, and
  MUST NOT declare loss on the basis of a single out-of-order arrival.
- **TS-VID-041**: A receiver MUST discard duplicate packets rather than
  feeding them to its depacketizer twice.
- **TS-VID-042**: A receiver operating without selective retransmission
  ([§9.1](#91-nack)) SHOULD hold an open sequence gap for at least a small
  fixed reorder window before declaring loss.
- **TS-VID-043**: A receiver operating with selective retransmission MUST
  hold an open gap for a duration long enough for a retransmission to
  arrive — at least 300 ms — rather than for a fixed number of packets, and
  MUST bound the buffer's memory independently. Abandoning a gap after a
  small packet count makes loss inside a keyframe unrecoverable.
- **TS-VID-044**: Declaring loss MUST NOT be the only trigger for recovery:
  a receiver MUST still be able to request a keyframe with `PLI` when a gap
  is abandoned.

---

## 8. Audio

### 8.1 Format

- **TS-AUD-001**: Audio MUST be Opus, monophonic, at a 48 000 Hz sample
  rate, with exactly one 20 ms frame (960 samples) per RTP packet.
- **TS-AUD-002**: The audio RTP clock rate is 48 000 Hz and the timestamp
  MUST advance by 960 per packet on a given SSRC.
- **TS-AUD-003**: A sender MUST set the marker bit on audio packets.
- **TS-AUD-004**: A sender MUST use payload type 98 for voice and 99 for
  system audio.
- **TS-AUD-005**: A receiver MUST demultiplex voice from system audio by
  payload type alone, and MUST discard an audio packet with any other
  payload type.
- **TS-AUD-006**: A receiver MUST discard an audio packet with an empty
  payload.

### 8.2 SSRC allocation

| SSRC | Stream |
| :--- | :----- |
| 0 | Sharer voice |
| 1 | Sharer system audio |
| ≥ 2 | Viewer voice, assigned by the sharer in `HELLO_ACK` |

- **TS-AUD-010**: A sharer MUST use SSRC 0 for its own voice and SSRC 1 for
  system audio, and MUST NOT assign either value to a viewer.
- **TS-AUD-011**: A sharer MUST assign viewer SSRCs from the range 2 …
  2^32−1.

### 8.3 Direction and relay

- **TS-AUD-020**: System audio flows sharer → viewer only. A sharer MUST
  discard an inbound audio packet whose payload type is 99.
- **TS-AUD-021**: A sharer MUST discard an inbound audio packet whose SSRC
  is not the SSRC it assigned to the sending viewer. Rule TS-AUD-020 and
  this rule together are what prevent a viewer from injecting counterfeit
  system audio.
- **TS-AUD-022**: A sharer that relays viewer voice to other viewers MUST
  forward the RTP packet unmodified, preserving the originating viewer's
  SSRC, so that receivers can separate speakers.
- **TS-AUD-023**: A sharer MUST NOT relay a viewer's voice back to that same
  viewer.
- **TS-AUD-024**: A sharer capturing system audio MUST exclude its own
  process's playback from the capture, so that received viewer voice is not
  re-transmitted as system audio.

---

## 9. Loss recovery

Three mechanisms sit in front of the keyframe path, each negotiated by a
capability bit. In increasing cost: XOR parity repairs a single loss with no
round trip; selective retransmission repairs arbitrary losses at one round
trip; `PLI` repairs anything at the cost of a keyframe.

- **TS-REC-001**: `PLI` MUST remain available regardless of what was
  negotiated. An implementation MUST NOT make keyframe recovery contingent
  on `NACK` or `FEC`.

### 9.1 NACK

```
[0x0A][count:1][(pid:2 BE)(blp:2 BE)] × count
```

`pid` is the first missing sequence number; `blp` is a bitmask of the 16
sequence numbers following it, bit *i* meaning `pid + 1 + i` is also
missing. These are the generic-NACK FCI semantics of
[RFC 4585 §6.2.1](https://www.rfc-editor.org/rfc/rfc4585#section-6.2.1).

- **TS-NCK-001**: A `NACK` MUST carry at most 16 entries, and a sender MUST
  truncate rather than exceed the limit.
- **TS-NCK-002**: A receiver MUST discard the whole `NACK` — not a prefix of
  it — if the datagram is shorter than `2 + 4·count`.
- **TS-NCK-003**: Sequence numbers in a `NACK` are in the sequence space of
  the requesting viewer's own stream, since each viewer receives an
  independently rewritten RTP header.
- **TS-NCK-004**: A sharer MUST retransmit a requested packet byte for byte,
  including its original sequence number, timestamp and marker bit.
- **TS-NCK-005**: A sharer MUST bound the buffer it retransmits from, and
  MUST fall back to producing a keyframe when a requested packet is no
  longer held.
- **TS-NCK-006**: A sharer MUST bound per-viewer retransmission bandwidth.
  The bound SHOULD NOT exceed 25 % of that viewer's video bitrate, and the
  sharer MUST fall back to a keyframe when a viewer exceeds it.
- **TS-NCK-007**: A viewer MUST NOT send a `NACK` for a gap that has not
  yet outlived its reorder tolerance. Reordering alone MUST NOT produce a
  retransmission request.
- **TS-NCK-008**: A viewer MUST NOT send a `NACK` for a sequence number it
  has already received, including one recovered by FEC.

### 9.2 Receiver reports and RTT

The sharer probes:

```
[0x0C][serverUptimeNs:8 BE]
```

The viewer reports, at three permitted lengths:

```
[0x0B][fracLostQ8:1][extHighestSeq:4 BE][jitterTicks:4 BE]
      [lastPingTs:8 BE][delaySincePingMs:2 BE]              — 20 bytes
      [fecRecovered:2 BE]                                   — 22 bytes
      [fecRecovered:2 BE][nackRecovered:2 BE]               — 24 bytes
```

- **TS-RRP-001**: A sharer that negotiated `receiverReport` SHOULD send
  `PING` about once per second, carrying a monotonic clock reading in
  nanoseconds.
- **TS-RRP-002**: A viewer MUST echo the most recent `PING` value it
  received in `lastPingTs`, and MUST report in `delaySincePingMs` the
  milliseconds elapsed between receiving that `PING` and sending the report.
- **TS-RRP-003**: A viewer that has received no `PING` MUST send
  `lastPingTs` and `delaySincePingMs` as zero, and a sharer MUST NOT derive
  an RTT from such a report.
- **TS-RRP-004**: A sharer MUST compute RTT as
  `now − lastPingTs − delaySincePingMs`, and MUST discard a report that
  yields a negative result.
- **TS-RRP-005**: A viewer SHOULD send a receiver report about once per
  second.
- **TS-RRP-006**: `fracLostQ8` is the fraction of packets lost over the
  reporting interval in units of 1/256.
- **TS-RRP-007**: `extHighestSeq` is the highest sequence number received,
  extended with the count of sequence-number wraps in its high 16 bits.
- **TS-RRP-008**: `jitterTicks` is the interarrival jitter in RTP timestamp
  units, computed as in [RFC 3550 §6.4.1](https://www.rfc-editor.org/rfc/rfc3550#section-6.4.1).
- **TS-RRP-009**: A receiver of a report MUST accept all three lengths,
  reading absent trailing counters as zero. A report of 21 or 23 bytes MUST
  be read as the next shorter form.
- **TS-RRP-010**: A viewer MUST count a packet recovered by FEC or by
  retransmission as **received** when computing `fracLostQ8`, and MUST
  report the recovered packets separately in `fecRecovered` and
  `nackRecovered`. Residual loss therefore drives rate control while
  `residual + fecRecovered + nackRecovered` reconstructs raw link loss.
- **TS-RRP-011**: A viewer MUST emit the 24-byte form only on a link where
  `fec` was negotiated in both directions, and MUST otherwise emit the
  20-byte form.
- **TS-RRP-012**: `fecRecovered` and `nackRecovered` are counts over the
  reporting interval, not cumulative totals.

### 9.3 FEC — XOR parity

```
[0x0D][baseSeq:2 BE][count:1][body:N]
```

One parity datagram covers a group of `count` **consecutive** media packets
beginning at `baseSeq` in the receiving viewer's sequence space. The body is
the XOR, over every member of the group, of

```
[len:2 BE][byte1][timestamp:4][payload …]
```

zero-padded to the longest member, where `len` is the member's total packet
length in bytes, `byte1` is byte 1 of its RTP header (marker bit and payload
type), `timestamp` is bytes 4–7 of its RTP header, and `payload` is
everything from byte 12 onward.

- **TS-FEC-001**: `count` MUST be in the range 2 … 16 inclusive. A receiver
  MUST discard a parity datagram declaring any other value.
- **TS-FEC-002**: A parity body MUST be at least 7 bytes. A receiver MUST
  discard a shorter one.
- **TS-FEC-003**: A parity body MUST NOT exceed 1107 bytes (the 7-byte
  prefix plus one maximum payload). A receiver MUST discard a larger one.
- **TS-FEC-004**: A group MUST consist of packets with consecutive sequence
  numbers, so that membership is fully described by `baseSeq` and `count`.
- **TS-FEC-005**: A group MUST NOT span two access-unit transmission
  batches. Parity for a group MUST be transmitted immediately after that
  group's last media packet, and MUST NOT be deferred to the end of a frame.
- **TS-FEC-006**: A sender MUST NOT emit parity for a group of fewer than
  two packets.
- **TS-FEC-007**: Parity datagrams MUST ride the control plane and MUST NOT
  consume a media sequence number. Losing parity therefore opens no gap.
- **TS-FEC-008**: A receiver MUST recover at most one missing packet per
  group. On two or more missing members it MUST fall back to `NACK` or
  `PLI`.
- **TS-FEC-009**: A receiver reconstructing a packet MUST XOR the received
  members' covered fields against the parity body and MUST build the
  recovered packet as byte 0 = `0x80`, byte 1 from the solved `byte1`, the
  known missing sequence number, the solved timestamp, the stream's SSRC,
  and the solved payload truncated to the solved `len`.
- **TS-FEC-010**: A receiver MUST discard a solve whose recovered `len` is
  less than 12 or exceeds the parity's padded payload region, and MUST NOT
  emit a truncated packet to its depacketizer.
- **TS-FEC-011**: A receiver MUST feed a recovered packet through the same
  ingest path as a received one, so that it is counted as received
  (TS-RRP-010) and clears the corresponding gap.
- **TS-FEC-012**: A receiver MUST tolerate the original of a recovered
  packet arriving late, discarding it as a duplicate.
- **TS-FEC-013**: A receiver MUST NOT change its reorder or NACK timing
  merely because `fec` was negotiated. It MUST do so only once parity
  datagrams are actually arriving, and MUST revert after parity has been
  absent for a period (3 s is RECOMMENDED).
- **TS-FEC-014**: A sharer SHOULD enable parity for a viewer only when that
  viewer's own measured path shows RTT above 150 ms **and** raw loss above
  2 %, and MUST NOT enable it for one viewer on the strength of another
  viewer's measurements.
- **TS-FEC-015**: A sharer SHOULD reduce group size as raw loss rises — 10
  packets below 4 %, 7 below 8 %, 5 above — and MUST NOT use a group size
  below 5 as a loss response.
- **TS-FEC-016**: A sharer that enables parity MUST reduce the encoder's
  target bitrate to `N/(N+1)` of the congestion-controlled rate while parity
  is on, so that media plus parity stays inside the same budget.
- **TS-FEC-017**: A sharer SHOULD disable parity only after two consecutive
  clean measurement windows, to avoid oscillation.

---

## 10. The framed TCP channel

Annotations, remote control, metadata and request-to-share share one TCP
connection and one framing.

```
[type:1][length:4 BE][payload:length]
```

### 10.1 Message-type registry

| Byte | Name | Direction | Payload |
| :--- | :--- | :-------- | :------ |
| `0x00`–`0x02` | — | — | Reserved, historical. MUST NOT be assigned. |
| `0x03` | `annotation` | viewer → sharer | `AnnotationOp` |
| `0x04` | `requestToShare` | peer → peer | `RequestToSharePayload` |
| `0x05` | `shareResponse` | responder → requester | `TailscreenRequest` |
| `0x06` | `controlRequest` | viewer → sharer | empty |
| `0x07` | `controlGranted` | sharer → viewer | empty |
| `0x08` | `controlRevoked` | sharer → viewer | `ControlRevokedPayload` |
| `0x09` | `inputEvent` | viewer → sharer | `InputEvent` |
| `0x0A` | `controlReleased` | viewer → sharer | empty |
| `0x0B` | `metadataRequest` | peer → peer | empty |
| `0x0C` | `metadataResponse` | responder → requester | `TailscreenMetadata` |

- **TS-TCP-001**: An implementation MUST encode each message with the type
  byte above. These values are permanent and MUST NOT be renumbered.
- **TS-TCP-002**: The TCP message-type space and the UDP control-byte space
  are independent. An implementation MUST NOT assume a byte means the same
  thing on both, and MUST NOT reject `0x0A`–`0x0C` on TCP because those
  values also name UDP messages.
- **TS-TCP-003**: A parser MUST consume the payload of a frame whose type it
  does not recognise and MUST continue parsing at the following frame. An
  unknown type is not an error.
- **TS-TCP-004**: A parser MUST reject a frame declaring a payload longer
  than 1 048 576 bytes (1 MiB) **before** buffering that payload.
- **TS-TCP-005**: On rejecting an oversized frame the parser MUST treat the
  connection as unrecoverable: it MUST stop parsing, MUST discard its
  buffer, MUST NOT resynchronise, and the owning receive loop MUST close the
  connection.
- **TS-TCP-006**: A parser MUST NOT emit a message until the whole declared
  payload has arrived, and MUST tolerate a frame arriving split across any
  number of TCP segments.
- **TS-TCP-007**: A parser MUST tolerate several frames arriving in one
  segment, emitting them in order.
- **TS-TCP-008**: A frame whose payload fails to decode MUST be discarded
  without disturbing the framing; the parser MUST continue with the next
  frame.
- **TS-TCP-009**: Payloads are JSON, encoded as UTF-8, with no trailing
  NUL and no length prefix of their own — the frame header carries the
  length.

### 10.2 Payload encodings

The JSON encodings below are normative. Field order is not significant;
absent optional fields MUST be treated as unset.

`RequestToSharePayload` (`0x04`):

```json
{"fromHostname": "studio-imac"}
```

`TailscreenRequest` (`0x05`):

```json
{"type": "acceptShare"}
{"type": "declineShare"}
{"type": "requestToShare", "from": "studio-imac"}
```

`ControlRevokedPayload` (`0x08`):

```json
{"reason": "the sharer ended remote control"}
```

`TailscreenMetadata` (`0x0C`):

```json
{
  "version": "1.0",
  "shareName": "Display 1",
  "hostname": "studio-imac",
  "screenResolution": {"width": 3840, "height": 2160},
  "isSharing": true,
  "timestamp": 776000000.0,
  "videoCodec": "hevc"
}
```

- **TS-TCP-020**: `timestamp` MUST be a JSON number giving seconds since
  2001-01-01T00:00:00Z (the Apple reference date), and MAY be fractional.
- **TS-TCP-021**: `videoCodec` is OPTIONAL and MUST be `"h264"` or
  `"hevc"` when present. A reader MUST treat its absence as H.264 and MUST
  NOT reject the message.
- **TS-TCP-022**: `version` is informational. A reader MUST NOT reject a
  message because of its value.
- **TS-TCP-023**: A reader MUST clamp `fromHostname` to 64 characters,
  `reason` to 128 characters, and `shareName` and `hostname` to 128
  characters before using them in a user interface. These strings are
  attacker-controlled.
- **TS-TCP-024**: A reader MUST accept a `controlRevoked` frame with an
  empty payload, treating the reason as absent.

---

## 11. Annotations

An annotation operation is one of add, undo, or clear-all, over a canvas
shared by the sharer and every viewer.

```json
{"type": "add", "annotation": {
  "id": "6C84FB90-12C4-11E1-840D-7B25C5EE775A",
  "tool": "pen",
  "points": [[0.25, 0.5], [0.3, 0.55]],
  "color": {"r": 1.0, "g": 0.1, "b": 0.15, "a": 1.0},
  "width": 3.0
}}
{"type": "undo", "id": "6C84FB90-12C4-11E1-840D-7B25C5EE775A"}
{"type": "clearAll"}
```

- **TS-ANN-001**: Annotation coordinates MUST be normalized to the range
  `[0, 1]` in the video frame's coordinate space with the origin at the top
  left.
- **TS-ANN-002**: A point MUST be encoded as a two-element JSON array
  `[x, y]`.
- **TS-ANN-003**: `tool` MUST be one of `pen`, `line`, `arrow`,
  `rectangle`, `oval`, `click`. A reader MUST discard an operation naming a
  tool it does not implement rather than rejecting the connection.
- **TS-ANN-004**: `id` MUST be a UUID string, and `undo` MUST name the `id`
  of a previously added annotation.
- **TS-ANN-005**: `width` is a stroke width relative to the video's short
  edge.
- **TS-ANN-006**: A sharer MUST honour an annotation operation only from a
  connection whose peer address matches an **admitted** viewer, and MUST
  discard operations from pending, denied, blocked or expelled peers —
  neither applying them locally nor relaying them.
- **TS-ANN-007**: A sharer that relays annotations MUST relay only
  operations it accepted under TS-ANN-006.
- **TS-ANN-008**: A sharer that advertised `annotations` (TS-CAP-008) MUST
  render accepted operations on its own display.

---

## 12. Remote control

Remote control is opt-in, single-grantee, and revocable at any moment.

### 12.1 Grant lifecycle

- **TS-RMT-001**: A viewer MUST request control with `controlRequest` and
  MUST NOT send `inputEvent` before receiving `controlGranted`.
- **TS-RMT-002**: A sharer MUST hold at most one grant at a time. Granting
  control to a second viewer MUST revoke the first with `controlRevoked`.
- **TS-RMT-003**: A sharer MUST accept a `controlRequest` only from an
  admitted viewer.
- **TS-RMT-004**: A sharer MUST admit `inputEvent` frames only from the
  exact TCP connection that holds the grant, identified by that connection,
  not by peer address. A grant MUST NOT survive the connection that
  received it.
- **TS-RMT-005**: A sharer MUST revoke the grant, sending `controlRevoked`
  where the connection still permits it, when the grantee disconnects, when
  the share stops, when the user revokes it, or when the grantee sends
  `controlReleased`.
- **TS-RMT-006**: A viewer that stops controlling SHOULD send
  `controlReleased` rather than relying on disconnection.
- **TS-RMT-007**: A sharer MUST enforce a ceiling on injected events per
  unit time, reset at each grant.
- **TS-RMT-008**: A sharer that lacks the operating-system permission to
  inject input MUST refuse the request with `controlRevoked` rather than
  accepting a grant it cannot honour.
- **TS-RMT-009**: On revoking a grant, a sharer MUST synthesize a
  button-up for any pointer button it believes to be held, so that revoking
  mid-drag cannot leave a button stuck down.
- **TS-RMT-010**: A sharer MUST drop any `inputEvent` that arrives after
  revocation, including one already queued for injection.

### 12.2 Input events

```json
{"mouseMove": {"x": 0.5, "y": 0.5}}
{"mouseDown": {"x": 0.5, "y": 0.5, "button": "left", "modifiers": 8}}
{"mouseUp":   {"x": 0.5, "y": 0.5, "button": "left", "modifiers": 8}}
{"scroll":    {"x": 0.5, "y": 0.5, "deltaX": 0.0, "deltaY": -3.0, "modifiers": 0}}
{"keyDown":   {"key": 4, "modifiers": 2}}
{"keyUp":     {"key": 4, "modifiers": 2}}
```

- **TS-RMT-020**: Pointer coordinates MUST be normalized to `[0, 1]` with
  the origin at the top left, the same convention as annotations.
- **TS-RMT-021**: `button` MUST be `left`, `right`, or `middle`.
- **TS-RMT-022**: `key` MUST be a USB HID **keyboard/keypad page (0x07)**
  usage identifier. An implementation MUST NOT put a platform-native
  keycode on the wire.
- **TS-RMT-023**: `modifiers` MUST be an integer bit field: bit 0 shift,
  bit 1 control, bit 2 alt/option, bit 3 meta/command/super, bit 4 caps
  lock. A receiver MUST ignore bits outside this set.
- **TS-RMT-024**: A receiver MUST construct native modifier flags from
  these bits rather than passing a wire value through to the operating
  system.
- **TS-RMT-025**: Modifier keys MUST NOT be sent as standalone key events.
  Their state rides the `modifiers` field of every key, button and scroll
  event, which keeps a mid-session join stateless.
- **TS-RMT-026**: A sender that must track modifier state itself MUST treat
  caps lock as a toggle flipped by its key-down, not as a held key, since no
  key-up follows.
- **TS-RMT-027**: `mouseMove` carries no modifiers. A receiver MUST NOT
  clear tracked modifier state on a `mouseMove`.
- **TS-RMT-028**: Scroll deltas are in line units. A receiver MUST convert
  them to its platform's scroll units.
- **TS-RMT-029**: A receiver MUST reject a frame whose coordinate or delta
  fields contain `NaN`, `Infinity`, `-Infinity`, or a value outside the
  range of a double, and MUST NOT clamp such a value into range.
- **TS-RMT-030**: A receiver MUST map normalized coordinates onto the
  currently captured region, not onto the whole desktop, and MUST confine
  the pointer to that region.
- **TS-RMT-031**: A receiver MUST drop a key event whose HID usage has no
  mapping on its platform, and MUST NOT substitute a different key.

---

## 13. Metadata and request-to-share

### 13.1 Request-to-share

- **TS-MET-001**: A requester MUST send `requestToShare` on a TCP
  connection it holds open, and MUST wait for the answer on that same
  connection.
- **TS-MET-002**: A responder MUST send `shareResponse` back on the
  connection the request arrived on. It MUST NOT dial the requester back;
  an address that answered a moment ago may belong to another peer now.
- **TS-MET-003**: A requester MUST treat a timeout or end-of-file as "no
  answer", which is also what a peer that predates `shareResponse`
  produces.
- **TS-MET-004**: A responder MUST deduplicate and bound pending requests
  by the peer's **source address**, not by any hostname claimed in the
  payload.
- **TS-MET-005**: A responder that accepts a request SHOULD pre-approve
  that source address for the share that follows, so the same person is not
  prompted twice seconds apart.
- **TS-MET-006**: A responder MUST bound how long it holds an unanswered
  request's connection open.

### 13.2 Metadata query

- **TS-MET-010**: A peer MUST answer `metadataRequest` with
  `metadataResponse` on the same connection.
- **TS-MET-011**: A peer that is not sharing MUST still answer, with
  `isSharing` false, so that "reachable but idle" is distinguishable from
  "no answer".
- **TS-MET-012**: A querier MUST treat every failure — timeout,
  end-of-file, or a peer that dropped the unknown type byte — as *status
  unknown*, and MUST NOT report it as "not sharing".
- **TS-MET-013**: `metadataResponse` MUST NOT carry information the tailnet
  does not already expose, beyond the share state a viewer would learn by
  connecting.

---

## 14. Discovery

- **TS-DSC-001**: An implementation MUST identify candidate peers from its
  own node's view of the tailnet (TS-GEN-017.4), and MUST NOT scan address
  ranges.
- **TS-DSC-002**: An installation's node hostname MUST begin with
  `tailscreen-`.
- **TS-DSC-003**: An ephemeral viewer-only node's hostname MUST begin with
  `tailscreen-client-`, and discovery MUST exclude such nodes from the list
  of connectable installations.
- **TS-DSC-004**: Discovery MUST NOT require a UDP or TCP probe to decide
  whether a peer is a Tailscreen installation; the tailnet's own liveness
  state is sufficient.
- **TS-DSC-005**: An implementation that queries peers for share status
  ([§13.2](#132-metadata-query)) MUST do so lazily — on an explicit refresh
  or when the user asks for the sharing-status filter — and MUST perform
  those queries concurrently rather than serially.

---

## 15. Versioning and extensibility

There is no protocol version number on the wire, and none is planned. The
protocol is extended by adding message types and capability bits, and
compatibility rests on one rule applied everywhere.

- **TS-EXT-001**: A receiver MUST ignore anything it does not understand —
  an unknown UDP control byte (TS-CTL-002), an unknown TCP message type
  (TS-TCP-003), an unknown capability bit (TS-CAP-002), an unknown
  annotation tool (TS-ANN-003), an unknown trailing field (TS-CTL-004,
  TS-RRP-009) — and MUST NOT treat it as an error.
- **TS-EXT-002**: An extension MUST be designed so that the ignore-unknown
  rule alone produces sensible degraded behaviour. An extension that
  requires both peers to understand it, with no defined degraded mode, MUST
  NOT be added to this protocol.
- **TS-EXT-003**: A shipped wire value MUST NOT be renumbered or reused for
  a different meaning. Withdrawn values stay reserved.
- **TS-EXT-004**: A new field MUST be appended to an existing message rather
  than inserted, so that an older parser reading a prefix still reads the
  right fields.
- **TS-EXT-005**: An implementation MUST NOT infer a peer's capabilities
  from its version string, hostname, or any other identifier. Capabilities
  are signalled only as defined in [§5](#5-capability-negotiation).

---

## 16. Security considerations

The protocol delegates confidentiality, integrity and peer authentication
entirely to the tailnet (TS-GEN-011, TS-GEN-017). What remains is authorization
and input validation, and those are Tailscreen's own responsibility.

- **TS-SEC-001**: Being able to reach port 7447 MUST NOT be treated as
  authorization to do anything. Every privileged action — receiving media,
  annotating, requesting control, injecting input — MUST be gated
  separately (TS-ADM-001, TS-ANN-006, TS-RMT-003, TS-RMT-004).
- **TS-SEC-002**: An implementation MUST treat every field of every inbound
  message as attacker-controlled, and MUST bounds-check lengths, counts and
  offsets before use (TS-TCP-004, TS-NCK-002, TS-FEC-001 … TS-FEC-003).
- **TS-SEC-003**: An implementation MUST NOT let an inbound message cause
  unbounded memory growth. Frame length, parity body size, pending-request
  count and per-viewer queues MUST all be bounded.
- **TS-SEC-004**: An implementation MUST NOT trust a peer-supplied
  identifier — hostname, share name, claimed node ID — for any authorization
  decision. Identity comes from the sharer's own view of the tailnet
  (TS-GEN-017.3, TS-ADM-006).
- **TS-SEC-005**: An implementation MUST NOT render a peer-supplied string
  without clamping its length (TS-TCP-023).
- **TS-SEC-006**: An implementation MUST NOT put a platform-native keycode,
  modifier mask, or event flag on the wire, and MUST construct native values
  from the neutral vocabulary instead (TS-RMT-022, TS-RMT-024).
- **TS-SEC-007**: A sharer MUST make an active remote-control grant visible
  to its own user and revocable without the grantee's cooperation.
- **TS-SEC-008**: An implementation SHOULD assume its peer is hostile and
  fuzz its parsers accordingly. Every parser defined here takes untrusted
  input.

---

## 17. Conformance

An implementation is **conformant** if it satisfies every MUST and MUST NOT
in this document for the roles it implements. An implementation MAY
implement the viewer role, the sharer role, or both; a requirement scoped to
a role it does not implement does not apply.

The repository carries a machine-readable conformance suite, and a second
implementation to run it against:

```
conformance/
├── README.md            how to run it, how to add a case
├── vectors/*.json       the vectors — language-neutral, one file per area
└── go/                  the runner

sdk/go/
├── tailscreen/          this specification, implemented in Go
├── capi/                the same, built as libtailscreen.a for C callers
└── ctest/               a C smoke test against that archive
```

`sdk/go` is written from this document and shares no code with the Swift
implementation the Tailscreen apps ship. Both are run against the same
vectors, which is what makes this document a contract rather than a
description: one side shows it says enough for an independent implementer,
the other shows it describes what actually ships. It is published for
third-party clients — as a Go module, and as a C static library built the way
`libtailscale.a` is.

- **TS-CNF-001**: Every vector cites the requirement identifiers it
  exercises. A change to a normative requirement MUST be accompanied by a
  change to the vectors that cite it.
- **TS-CNF-002**: A new wire value MUST arrive with both a registry row
  ([Appendix A](#appendix-a-wire-value-registry)) and at least one vector.
- **TS-CNF-003**: The vectors are the contract; an implementation that
  passes them is not thereby proven conformant, since not every requirement
  is mechanically testable, but one that fails them is definitively not.

Run the Go suite with:

```bash
make test-conformance      # the vectors, against sdk/go
make test-protocol         # the same vectors, against the Swift codecs
make fuzz-conformance      # coverage-guided fuzzing of sdk/go's parsers
make libtailscreen-check   # the C archive and its ABI
```

- **TS-CNF-004**: An implementation SHOULD fuzz its parsers against structural
  invariants — a successful decode never claims more bytes than it was given,
  a rejection stays rejected, anything the encoder produces the decoder reads
  back. Every parser this document defines takes untrusted input
  (TS-SEC-008), and the vectors only cover input somebody meant to send.

---

## Appendix A. Wire value registry

Every value Tailscreen puts on a socket. Values are permanent (TS-EXT-003).

### A.1 UDP control bytes

| Value | Name | Since |
| :--- | :--- | :--- |
| `0x00` | `HELLO` | 1 |
| `0x01` | `KEEPALIVE` | 1 |
| `0x02` | `BYE` | 1 |
| `0x03` | `PLI` | 1 |
| `0x04` | `HELLO_ACK` | 1 |
| `0x05` | `SERVER_BYE` | 1 |
| `0x06` | `HELLO_PENDING` | 1 |
| `0x07` | `CODEC_NO` | 1 |
| `0x08` | `HELLO_DENY` | 1 |
| `0x09` | `PROFILE_NO` | 1 |
| `0x0A` | `NACK` | 1 |
| `0x0B` | `RECEIVER_REPORT` | 1 |
| `0x0C` | `PING` | 1 |
| `0x0D` | `FEC` | 1 |
| `0x0E`–`0x7F` | unassigned | — |

### A.2 TCP message types

| Value | Name | Since |
| :--- | :--- | :--- |
| `0x00`–`0x02` | reserved (historical) | — |
| `0x03` | `annotation` | 1 |
| `0x04` | `requestToShare` | 1 |
| `0x05` | `shareResponse` | 1 |
| `0x06` | `controlRequest` | 1 |
| `0x07` | `controlGranted` | 1 |
| `0x08` | `controlRevoked` | 1 |
| `0x09` | `inputEvent` | 1 |
| `0x0A` | `controlReleased` | 1 |
| `0x0B` | `metadataRequest` | 1 |
| `0x0C` | `metadataResponse` | 1 |
| `0x0D`–`0xFF` | unassigned | — |

### A.3 Capability bits

| Bit | Name | Direction |
| :--- | :--- | :--- |
| 0 | `nack` | both |
| 1 | `receiverReport` | both |
| 2 | `fec` | both |
| 3 | `remoteControl` | sharer |
| 4 | `annotations` | sharer |
| 5–7 | unassigned | — |

### A.4 RTP payload types

| Value | Media |
| :--- | :--- |
| 96 | H.264 |
| 97 | HEVC |
| 98 | Opus voice |
| 99 | Opus system audio |

### A.5 Reserved SSRCs

| Value | Stream |
| :--- | :--- |
| 0 | Sharer voice |
| 1 | Sharer system audio |
| ≥ 2 | Viewer-assigned |

### A.6 Key modifier bits

| Bit | Modifier |
| :--- | :--- |
| 0 | shift |
| 1 | control |
| 2 | alt / option |
| 3 | meta / command / super |
| 4 | caps lock |
| 5–15 | unassigned |

---

## Appendix B. Constants

| Constant | Value | Requirement |
| :--- | :--- | :--- |
| Port (provisional default, not IANA-registered) | 7447 (TCP and UDP) | TS-GEN-010, TS-GEN-016 |
| Max RTP payload | 1100 bytes | TS-VID-030 |
| Video clock | 90 000 Hz | TS-VID-007 |
| Audio clock | 48 000 Hz | TS-AUD-002 |
| Opus frame | 960 samples (20 ms) | TS-AUD-001 |
| Keepalive interval | 500 ms | TS-CTL-015 |
| Idle timeout, both ends | 15 s | TS-CTL-016, TS-CTL-017 |
| Pending-approval timeout | 60 s | TS-ADM-003 |
| Expelled quiet window | 30 s | TS-ADM-008 |
| NACK entries per datagram | ≤ 16 | TS-NCK-001 |
| Retransmission budget | ≤ 25 % of video bitrate | TS-NCK-006 |
| Reorder hold with NACK | ≥ 300 ms | TS-VID-043 |
| FEC group size | 2 … 16 | TS-FEC-001 |
| FEC parity body | 7 … 1107 bytes | TS-FEC-002, TS-FEC-003 |
| FEC on-gate | RTT > 150 ms and loss > 2 % | TS-FEC-014 |
| Parity idle disarm | 3 s | TS-FEC-013 |
| Max TCP frame payload | 1 MiB | TS-TCP-004 |
| Hostname clamp | 64 characters | TS-TCP-023 |
| Reason / display-string clamp | 128 characters | TS-TCP-023 |

---

## Appendix C. Change log

| Version | Change |
| :--- | :--- |
| 1 | Initial specification, describing the protocol as shipped. |
| 1 | Stated the substrate as a **tailnet** with four named properties (TS-GEN-017 … TS-GEN-019) rather than as Tailscale specifically, so that headscale — already supported and exercised by the end-to-end harness — is inside the specification rather than outside it. A widening: everything conforming before still conforms. |
