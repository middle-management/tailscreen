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

| Channel       | Transport | Purpose                                                              |
| :------------ | :-------- | :------------------------------------------------------------------- |
| Video         | UDP/7447  | H.264 over RTP (RFC 3984). Lossy on purpose.                         |
| Annotations   | TCP/7447  | Length-framed JSON messages. Reliable on purpose.                    |
| Metadata      | TCP/7447  | Share name, resolution, request-to-share prompts.                    |
| Discovery     | TCP/7447  | Probe across the tailnet to find Tailscreen peers.                   |

A note for anyone planning to make `7447` configurable: it's hardcoded in
four places — `TailscalePeerDiscovery`, `TailscaleScreenShareServer`,
`TailscaleScreenShareClient`, and `TailscreenMetadataService`. You'll need
to change all four together, or the discovery will quietly fail to find
anything.

## Video — UDP RTP

H.264 NAL units packetized per RFC 3984. The implementation is in
[`RTPPacket.swift`](https://github.com/middle-management/tailscreen/blob/main/Sources/RTPPacket.swift).

Two things worth calling out:

**SPS/PPS go in-band, on every keyframe.** Most RTP H.264 implementations
shove parameter sets into out-of-band SDP. We don't have an SDP — there's
no signaling step, viewers can connect at any time, and we don't want them
waiting for a control-plane handshake to get the decoder primed. So we
just ship SPS/PPS with each keyframe. The cost is a few hundred bytes per
keyframe; the benefit is that "viewer connects, sees pixels in under a
second" works even with no prior handshake.

**Keyframe-on-PLI.** The viewer sends a Picture Loss Indication when it
detects a gap in sequence numbers it can't recover from. The encoder
forces a keyframe in response. Combined with the periodic ~2-second
keyframe schedule, this means a transient loss costs you milliseconds of
artifacts, not seconds of green frames. UDP loss is fine. We chose UDP
*because* loss is fine here.

## Annotations / control — TCP

Length-prefixed framing on top of TCP, defined in
[`ScreenShareProtocol.swift`](https://github.com/middle-management/tailscreen/blob/main/Sources/ScreenShareProtocol.swift):

```
[type: 1 byte][len: 4 bytes, big-endian UInt32][payload: N bytes]
```

The payload is a JSON-encoded `AnnotationOp`. Yes, it's JSON. Yes, you
could shave bytes with a binary encoding. No, it doesn't matter — strokes
are tens of bytes each, and the bandwidth budget for annotations is
rounding error compared to the video.

Why TCP for this and UDP for video? Because **dropping a stroke segment is
visible and confusing; dropping a video frame is invisible.** A user who
sees their circle drawn as two disconnected arcs immediately concludes
"this software is broken." A user who experiences a 16ms frame stutter
during a fast camera pan does not. The transport choice tracks the cost of
loss.

## Metadata — TCP request/response

`TailscreenMetadataService` listens on the same TCP/7447 socket and
responds to a few simple request types: "who are you?", "what's your
resolution?", and the request-to-share prompt that lets the sharer require
manual approval before video starts flowing.

This isn't its own port for a reason: opening a second port would mean a
second hole in any tailnet ACL and a second TCP probe in discovery. One
port, multiple channels, separated by the framing byte.

## Discovery probe

`TailscalePeerDiscovery` enumerates peers from the local tsnet LocalAPI,
then opens TCP/7447 to each peer in parallel with a short timeout. Peers
that accept and reply with the Tailscreen handshake show up in **Browse
Shares**. Peers that don't, don't.

The probe is parallel because tailnets get big, and a serial probe of 50
peers with a 500ms timeout each is 25 seconds of staring at a spinner.
Parallel, it's 500ms total.

## A footnote about the legacy framing

There's an older single-stream framing in
[`ScreenShareServer.swift`](https://github.com/middle-management/tailscreen/blob/main/Sources/ScreenShareServer.swift)
and
[`ScreenShareClient.swift`](https://github.com/middle-management/tailscreen/blob/main/Sources/ScreenShareClient.swift):

```
[size: 4 bytes][keyframe: 1 byte][data: N bytes]
```

This is the **non-Tailscale** code path — kept as reference for the
pre-tsnet design. The active path is everything else on this page (RTP
over UDP for video, framed TCP for everything else). If you're modifying
networking code and end up in `ScreenShareServer.swift` thinking "this is
the protocol", back out — that's not the file you want.
