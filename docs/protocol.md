---
title: Network Protocol
nav_order: 5
permalink: /protocol/
---

# Network protocol
{: .no_toc }

1. TOC
{:toc}

Tailscreen uses a **single port — `7447`, on both TCP and UDP** — for all
peer-to-peer traffic. Everything rides over the encrypted Tailscale
WireGuard tunnel.

| Channel       | Transport | Purpose                                                                   |
| :------------ | :-------- | :------------------------------------------------------------------------ |
| Video         | UDP/7447  | H.264 over RTP (RFC 3984). Loss-tolerant, no buffering.                   |
| Annotations   | TCP/7447  | Reliable framed messages so strokes don't drop.                           |
| Metadata      | TCP/7447  | Share name, resolution, request-to-share prompts.                         |
| Discovery     | TCP/7447  | Parallel probe across the tailnet to identify Tailscreen peers.           |

Port `7447` is hardcoded in four places: `TailscalePeerDiscovery`,
`TailscaleScreenShareServer`, `TailscaleScreenShareClient`, and
`TailscreenMetadataService`. If you ever make it configurable, change all
four together.

## Video — UDP RTP

- AVCC NAL units, packetized per RFC 3984 in [`RTPPacket.swift`](https://github.com/middle-management/tailscreen/blob/main/Sources/RTPPacket.swift).
- SPS/PPS are sent **in-band on every keyframe** so a late-joining viewer
  can sync without an out-of-band handshake.
- Keyframes are emitted roughly every 2 seconds, or earlier on a PLI
  (Picture Loss Indication) from the viewer.
- No buffering — UDP loss is accepted in exchange for lower latency.

## Annotations / control — TCP

A simple length-prefixed framing on top of TCP, defined in
[`ScreenShareProtocol.swift`](https://github.com/middle-management/tailscreen/blob/main/Sources/ScreenShareProtocol.swift):

```
[type: 1 byte][len: 4 bytes, big-endian UInt32][payload: N bytes]
```

The payload is a JSON-encoded `AnnotationOp`. TCP gives reliable, ordered
delivery so individual stroke segments are never dropped, even when video
packets are.

## Metadata — TCP, request/response

`TailscreenMetadataService` serves metadata requests over the same TCP/7447
port. The sharer responds with display name, resolution, and any
"request-to-share" prompts before media flows.

## Discovery probe

`TailscalePeerDiscovery` enumerates peers from the local tsnet LocalAPI,
then opens TCP/7447 in parallel against each peer with a short timeout. Any
peer that accepts the connection and replies with the Tailscreen handshake
shows up in **Browse Shares...**.

## Legacy single-stream framing

A different framing exists in
[`ScreenShareServer.swift`](https://github.com/middle-management/tailscreen/blob/main/Sources/ScreenShareServer.swift)
and
[`ScreenShareClient.swift`](https://github.com/middle-management/tailscreen/blob/main/Sources/ScreenShareClient.swift):

```
[size: 4 bytes][keyframe: 1 byte][data: N bytes]
```

This is the **legacy non-Tailscale** path, kept as reference. The active
Tailscale path is RTP/UDP for video plus the framed TCP control channel
above. Don't confuse the two when modifying code.
