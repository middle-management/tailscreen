# Browser viewer — the stream profile, the wasm transport, and the page

> Status: plan. This is the "separate plan" `plans/share-by-token.md` deferred
> ("Browser viewer (needs the reliable-transport profile; separate plan)").
> Feasibility groundwork: `plans/tailcat-evaluation.md`, "Use case 2: browser
> viewer" — read it first; this document turns its findings into a build
> order against what has shipped since (the guest tunnel, the fork's `guest`
> package, `sdk/go`).

## What ships

A guest clicks a share link and watches the share **in a browser tab** — no
app install, no Tailscale account, nothing on the machine. The page dials the
sharer through the same `tc…` token every native guest uses, lands in the
same mandatory per-join approval queue, and renders the same H.264/HEVC
stream via WebCodecs. The sharer needs no browser-specific anything: a
browser viewer is just a guest whose media rides the **stream profile** — the
one protocol addition this plan makes, useful on its own long before any
wasm exists.

## Why the browser can't be a fourth app

The guest tunnel is not the obstacle. It carries UDP fine — native guests get
the full RTP media path today (`guestPacketListener`, `MediaSockets`). The
obstacle is the browser runtime, twice over:

1. **No UDP, ever.** A js/wasm build has no datagram socket and cannot
   hole-punch. The only path out is WireGuard-over-WebSocket via DERP —
   workable (it is how the guest bootstrap already reaches the relay), but
   the tunnel then carries only stream-shaped traffic, and every browser
   viewer is **relayed**, at full share bitrate. On the free relays that is
   not viable; on a self-hosted derper (`docs/self-hosted.md`) it is a
   capacity question the deployment controls.
2. **Loss recovery becomes dead weight.** FEC → NACK → PLI exists because
   datagrams get lost. A reliable in-order stream never loses a packet, so
   parity is wasted bitrate, retransmission is actively wrong (the transport
   already retransmitted), and the reorder buffer's time-held gaps hold for
   nothing. What replaces loss on a stream is **delay** — head-of-line
   blocking and queueing — which wants a different sender, not a different
   receiver.

So the prerequisite is a protocol profile that carries the existing datagram
plane over a reliable byte stream, with the loss-recovery machinery
negotiated off. That profile is Phase 1, it lands natively (all three apps
gain a "UDP is blocked" fallback from it), and everything browser-specific
stacks on top without touching the sharer again.

## The design: datagrams framed over the stream

One new wire value, and almost no new machinery.

### One new TCP message type

The framed TCP channel already reaches every viewer, already runs over the
guest tunnel (`start(adopting:)`), and already skips unknown types
(TS-EXT-001). Add one type to `ScreenShareMessageType`
(`Packages/TailscreenKit/Sources/TailscreenProtocol/ScreenShareProtocol.swift`)
and its Go twin (`sdk/go/tailscreen/frame.go`):

| Value | Name | Direction | Payload |
| :- | :- | :- | :- |
| `0x0D` | `mediaDatagram` | both | exactly the bytes of one UDP/7447 datagram |

The payload is demultiplexed by its first byte precisely as TS-GEN-020
demultiplexes a UDP datagram: RTP if `(byte0 & 0xC0) == 0x80`, control
otherwise; an empty payload is discarded (mirroring TS-GEN-022). Every
datagram the protocol defines — HELLO, HELLO_ACK, KEEPALIVE, PLI, RR, PING,
BYE, RTP video and audio — rides unchanged as a frame payload. Media
datagrams are ≤ ~1108 bytes (Appendix B), so nothing approaches the 1 MiB
frame cap, and framing each datagram individually gives the sender a natural
interleave point: a control frame (`controlRevoked`, an annotation) is never
stuck behind more than one ~1.1 KB media frame, so sharing the connection
with the existing channel costs at most a millisecond of head-of-line, not a
keyframe's worth.

### Mode entry: where the HELLO arrives

No capability bit, no negotiation message. A viewer that cannot (or is told
not to) use UDP opens the framed TCP channel and sends its HELLO **as a
`mediaDatagram` frame**. The sharer answers on the same connection —
HELLO_ACK/PENDING/DENY as frames — and from then on that viewer's entire
datagram plane rides that connection. The connection *is* the viewer's
address:

- TS-GEN-012's "send media to the source of the HELLO" becomes "send to the
  connection the HELLO arrived on" — same rule, same shape as
  request-to-share's answer-on-the-arrival-connection (TS-GEN-014 still
  holds: one TCP connection per viewer, now carrying media too).
- Admission is untouched: the connection's remote address is the viewer's
  identity anchor exactly as it is for annotations today (the
  `isAdmittedViewerIP` gate, bracket-form IPv6 pitfall included), and for a
  guest that address maps to the WireGuard node key as it does now.
- Connection close is BYE (viewer→sharer) / SERVER_BYE (sharer→viewer).
  KEEPALIVE still flows (as frames) so the 15 s idle sweep stays uniform.

Degradation is clean in both directions: a legacy sharer drops the unknown
`0x0D` frames, the viewer's HELLO gets no answer, and the join times out
with "sharer doesn't support stream viewing"; a legacy viewer never sends
`0x0D` and nothing changes.

### What turns off, what stays

- A stream viewer **MUST NOT** advertise `nack` (bit 0) or `fec` (bit 2),
  and a sharer **MUST NOT** send retransmissions or `0x0D` FEC parity
  datagrams to a stream viewer regardless of what was advertised.
- `receiverReport` (bit 1) **SHOULD** be advertised: loss will read ~0, but
  the RR still carries jitter, the PING echo (RTT), and the ~1 Hz liveness
  the congestion controller keys on.
- PLI keeps its exact role: decode failure, codec fallback (CODEC_NO /
  PROFILE_NO), and the depacketizer's discontinuity path. In fact a stream
  viewer is behaviourally the **legacy PLI-only viewer** the protocol has
  supported since day one, minus the packet loss — the degraded mode is
  already fully specified and shipped; the profile mostly *removes* rules.

### Sender-side drop replaces network loss

On UDP the network drops packets; on a stream nobody does, so the sharer
must be allowed to, or a slow viewer's queue grows without bound.
Implementation (and the spec's TS-STM-006) turned out to need **nothing
new**: the shipped fan-out already is the backpressure machinery.

- Each viewer has its own **send chain** with a queued-frames cap
  (`videoSendTails` / `maxQueuedVideoFramesPerViewer`): a stream viewer's
  blocking TCP write backs up only its own chain, and frames past the cap
  are shed whole. A shed keeps its reserved seq range, so the viewer sees a
  gap and PLIs — which on this transport can only mean sender-side
  omission, and the keyframe request recovers it (the legacy PLI-only path
  every sharer serves).
- Sustained pressure then rides the existing fairness loop: the PLIs mark
  the viewer `.isolated`, and the keyframe-only throttle
  (`shouldSendFrame`) skips inter frames **contiguously** — the throttle
  deliberately doesn't reserve seqs for skipped frames, so the slideshow
  is gap-free. Spec'd as SHOULD-contiguous with the gap-shed explicitly
  permitted (TS-STM-006).

So the "new backpressure decision function" this plan originally called
for dissolved on contact with the code: TCP write blocking → chain backlog
→ shed → PLI → fairness throttle is the same response path a slow UDP
viewer gets today, signal included. What stream mode adds is only the
route (datagrams framed onto the connection) and the caps mask.

### Spec, registry, vectors

A wire change lands in one commit across four places (CLAUDE.md); for this
profile that means:

- **`docs/spec.md`**: a new §2.2 "Stream carriage of the datagram plane
  (reliable-transport profile)" with `TS-STM-0xx` requirement IDs covering
  the rules above; a row in the §10.1 message-type registry and Appendix A.2
  (`0x0D mediaDatagram`, Since 2); a change-log row; the §2 channels table
  gains the stream rows. Spec version bumps to 2 (`index.json`'s
  `specVersion` moves with it) — Appendix D could stay at 1 because it added
  no wire value; this adds one.
- **`WireByteRegistryTests`**: the `0x0D` row in the TCP table (TCP types
  and UDP control bytes overlap by design; `0x0D` is FEC on UDP,
  `mediaDatagram` on TCP — disjoint spaces, same as `0x0B`/`0x0C` today).
- **`conformance/vectors/tcp-framing.json`**: encode/decode cases for a
  `mediaDatagram` frame wrapping a HELLO, wrapping an RTP packet, and the
  empty-payload-discard rule (TS-CNF-002).
- **Code**: both message-type enums, Swift and Go.

## Phase 1 — the stream profile, native

No browser anywhere in this phase; it is useful stand-alone as the fallback
for any viewer on a UDP-blocking network, on every platform.

1. Spec + registry + vectors + both enums, one commit (above).
2. **Sharer**: `TailscreenControlListener` routes `0x0D` payloads to a new
   handler; `TailscaleScreenShareServer` registers a viewer whose HELLO
   arrived framed as a *stream viewer* — its media route is the connection
   (a third leg beside `MediaSockets`' primary/guest, keyed by connection
   ID), its sends go through a per-viewer outbox with control-frame
   priority, and its congestion input is outbox depth via the new decision
   function. FEC grouping and the retransmit ring simply never see stream
   viewers.
3. **Viewer**: `ViewerSession` is already transport-agnostic (bytes in,
   clock in). `TsnetTransport`/`ViewerBackChannel` gain a stream mode: the
   session's outbound control datagrams are wrapped in `0x0D` frames on the
   back-channel, inbound `0x0D` payloads feed `receiveRTP`/control ingest.
   Forced by `TAILSCREEN_FORCE_STREAM=1` for testing; automatic fallback
   (UDP silent after HELLO retries → retry framed) is a follow-up, not part
   of the gate.
4. Tests: decision suites for the backpressure function and the
   stream-viewer registration; `ConformanceVectorTests` picks the new
   vectors up for free; an impairment leg using the existing
   `net-impair.sh`/`test-local.sh` affordances with UDP blackholed. The
   differential suite needs no new leg — past the demux the pipeline is
   byte-identical, which is the point of the design.

**Gate**: a native viewer watches a share with UDP fully blocked, all three
sharer hosts serve it, `make test-protocol` / `test-conformance` /
`test-differential` green.

## Phase 2 — the wasm transport spike

> Status: **done** (this branch). The gate is met end to end with no
> internet: real Chromium → the fork's `guest` client compiled to wasm →
> DERP over WebSocket → WireGuard → the real Linux sharer in link-only mode,
> a framed HELLO electing the stream profile, parked → approved → HELLO_ACK,
> then video RTP arriving over the stream. `make test-web-spike` runs it;
> CI's `linux-web-spike` leg pins it.

The one genuinely unproven piece came first, on the eval's own discipline,
and it retired in a single command: **the `guest` package compiles for
`GOOS=js GOARCH=wasm` unchanged** — magicsock's js support and derphttp's
WebSocket dial (the tsconnect lineage) carry it, and the package's
`pickregion_js.go` was already there from tailcat. Nothing landed in the
fork; the submodule pointer is untouched.

What the spike built, all under `web/viewer`:

- **The module** (`web/viewer/go.mod`): `replace`s onto the submodule path
  for the fork and onto `../../sdk/go` for the SDK, so the wasm build and
  the c-archive build pin the same fork commit. `main_js.go` exports a
  deliberately small surface — `tailscreenGuestDial(token)` returning a
  conn with `read`/`write`/`close`, plus `tailscreenFrameEncode` /
  `tailscreenNewFrameParser` / `tailscreenHello` / `tailscreenControl` /
  `tailscreenClassify` — every byte of which is sdk/go, so the page never
  re-implements a wire format. `sdk/go` compiles to wasm as-is, as
  predicted: it was written socketless and clock-injected.
- **`cmd/localderp`**: the relay fleet stood in by one process — a DERP
  server over TLS with a throwaway self-signed certificate and WebSocket
  support (the only way a browser reaches DERP), a STUN responder, and a
  plain-HTTP `/derpmap` pointing back at itself with `InsecureForTests`.
  That flag is what makes the self-signed cert workable on both ends: the
  native side skips verification for such a node, the browser is launched
  with certificate errors ignored.
- **`index.html` + `viewer.js`**: the loop — token from the URL fragment
  (never sent to any server), dial, HELLO as a `mediaDatagram` frame (the
  election, TS-STM-002; legacy one-byte HELLO so no NACK/FEC per
  TS-STM-005), HELLO re-sent on the keepalive cadence until answered, then
  KEEPALIVE (TS-STM-004), and every returning frame classified and counted.
  `window.__spike` is what the harness asserts on.
- **`e2e/spike.mjs`** (Playwright): boots localderp, Xvfb with a gradient
  on it, the sharer, then Chromium, and asserts `acked` followed by ≥ 50
  video datagrams. One run here: admitted with an assigned SSRC, 180 video
  datagrams over the stream in the first seconds, no corrupt frames.
- **`tailscreen-sharer-linux --link`**: the headless sharer gains the
  link-only share (`startGuestOnly`, no tsnet, no headscale) with
  `--link-relay-map-url` for a local relay and `--approve-guests` as the
  unattended twin of `TAILSCREEN_OPEN_DOOR`; it prints the same
  `E2E_MARKER shareLink token=…` the macOS app prints under
  `TAILSCREEN_AUTOSHARE_LINK`.

**Measured sizes** (`-trimpath -ldflags="-s -w"`, Go 1.26.6):

| | |
| :- | :- |
| `viewer.wasm` | 33.9 MB |
| gzip -9 | 7.8 MB |
| brotli -q 11 | 5.4 MB |

The eval's ~27 MB reference was tailcat's demo; ours carries the whole
`guest` package (server half included — it is one package) and sdk/go. The
number that matters for first load is the brotli one, and it is the Phase 4
size-budget input rather than something to optimise here.

**The one bug worth recording.** The first run failed with the sharer's
relay connection closing "age 0s" right after the token was minted, and
every browser handshake going unanswered: the CLI let its `GuestServerNode`
go out of scope after `token()`, and the node closes on deinit — the server
adopts only its *listeners*. `SharerLinkSession` holds the node in a
property for exactly this reason; the CLI now does too, and the comment on
`linkNode` says why.

**Not done here, deliberately:** decoding (Phase 3), receiver reports from
the page (it advertises no caps yet), and any UI beyond a status readout.

## Phase 3 — the page

> Status: **done** (this branch). Chrome watches a live share: the wasm
> session hands access units to WebCodecs, frames land on a canvas, Opus
> plays through an AudioContext, and the placards come from the shared
> catalog. `make test-web-spike` now asserts decoded frames and a non-flat
> canvas; CI's `linux-web-spike` runs it on Google Chrome.

What the page is, as built:

- **The session, in the wasm.** `sdk/go`'s reorder buffer, depacketizers
  and receiver-report accounting, driven by the page's clock exactly the
  way the SDK asks — `ingest(datagram, nowNs)` yields access units and
  audio frames, `tick(nowNs)` yields what to send: HELLO until answered,
  KEEPALIVE at the spec cadence, receiver reports with the PING echo
  (`receiverReport` is the one capability advertised, per TS-STM-005), a
  rate-limited PLI for the first keyframe and after decode failures, and
  CODEC_NO once when asked. Each AU carries its in-band parameter sets and
  an RFC 6381 codec string, so the page never parses a bitstream.
- **Video: WebCodecs → canvas.** H.264 in "avc" form — the depacketizer's
  AVCC as-is, with an avcC description built from the SPS/PPS, the format
  every engine accepts; HEVC as Annex B with an `hev1.…` string derived
  from its SPS. A decoder that reports the config unsupported takes the
  existing escape hatch: CODEC_NO latches the share to H.264. Decode
  errors reset the decoder and ask for a keyframe; a decode queue that
  backs up sheds to the next keyframe rather than build latency.
- **Audio: Opus → AudioContext**, one `AudioDecoder` per SSRC (voice and
  system audio share the path), scheduled with a small lead and re-anchored
  when it drifts, behind the click the browser requires. Listen-only.
- **Chrome and strings.** Approval / declined / ended placards, a stats HUD
  (`s`), full screen, a log pane; the share's name in the title via a
  `metadataRequest` on the same connection. Placard text is the shared
  TailscreenL10n catalog, exported to `dist/strings.json` at build time by
  `tools/export_strings.py` from the keys in `tools/strings.txt` — a
  string translated once (English and Swedish today) is translated in the
  browser too; keys the catalog lacks degrade to English.

**One measurement worth knowing.** Playwright's own Chromium ships without
the proprietary codecs: WebCodecs is present but reports every H.264 and
HEVC configuration unsupported (VP8, AV1 and Opus are fine). Google Chrome
decodes H.264 in every profile, Annex B included, and Opus — HEVC not on
Linux, which is exactly the CODEC_NO case. So the harness prefers Chrome
when present (`PW_CHANNEL` overrides), degrades to transport-only
assertions otherwise, and CI installs Chrome. The gate run here:

```
decoded 34 frames (avc1.42C01F, 1280×720, 15 fps); AUs 33, dropped 0, errors 0; canvas luma spread 18.5
PASS — viewer.wasm=34.01MB viewer.wasm.gz=7.78MB viewer.wasm.br=5.46MB
```

**Not done here, deliberately:** annotations and remote control from the
page, the microphone, hosting, and the docs-site pages — Phase 4. Safari
and Firefox have not been run against a live share yet (no headless
build of either here); the "avc" + avcC choice is the compatible one for
both, and it is the first thing to check when they are.

## Phase 4 — chrome and shipping

> Status: **done** (this branch). Remote control and drawing from the page,
> the page hosted on the site, the web form of a share link in all three
> apps, and the docs — with the browser as a fourth column of the platform
> matrix, honestly filled.

**Remote control and annotations** turned out to be what the plan said:
framed JSON on the connection the page already holds. `wire.js` is the pure
half — the W3C `KeyboardEvent.code` → USB HID usage table (TS-RMT-022),
the modifier bit field (TS-RMT-023), the §12.2 and §11 JSON builders, and a
small store that renders received annotations — checked without a browser
by `e2e/wire.test.mjs` against the spec's own examples. `viewer.js` puts an
overlay canvas over the stage that serves one mode at a time: **control**
(pointer moves throttled to the sharer's rate ceiling, buttons, wheel in
line units, keys — never the modifier keys themselves, TS-RMT-025) or
**draw** (pen strokes sent as one `add` per stroke, undo of your own,
clear-all, five colours), and renders whatever `annotation` frames the
sharer relays. Both are gated the way the apps gate them: on the sharer's
advertised `remoteControl` and `annotations` bits, hidden rather than
disabled. Nothing on the sharer changed — the grant gate was already
connection-scoped, and a stream viewer's connection is exactly the one its
framed JSON arrives on.

The e2e now drives remote control **end to end**: the sharer runs
`--allow-control --grant-control` (the new auto-grant twin of
`--approve-guests`), the page presses Request control, a real pointer move
over the stage becomes an XTEST move on the Xvfb, and `xdotool` reads the
pointer back within a few pixels of where the page pointed. It also asserts
the drawing tools stay hidden — a headless sharer renders nothing, so it
advertises nothing (TS-ANN-008 is a MUST, and a test sharer that lied to
get a stroke through would be testing the wrong thing).

**Hosting.** GitHub Pages will not compress `application/wasm`, and 34 MB
raw is not a first load anyone should pay for 7.8 MB of content. So the
page fetches the pre-compressed `viewer.wasm.gz` and inflates it with
`DecompressionStream` (Chrome 80+, Firefox 113+, Safari 16.4+), falling
back to the raw file only where that API is missing. `pages.yml` builds the
wasm (setup-go from the fork's `go.mod`, submodule checked out) and
publishes the page under `/next/view/` always and `/view/` once the latest
stable release carries it — the same channel rule as the docs. For a
network with no web access, `make web-viewer-bundle` inlines everything,
the gzipped wasm as base64, into one HTML file that the same loader
recognises.

**Links.** `ShareLinkFormat.webLink(token:)` is
`https://tailscreen.dev/view/#tc…` — the token in the **fragment**, so the
host of the page never sees it — and `token(fromUserInput:)` now accepts
that form from any host (the page is static and self-hostable, so the host
proves nothing; the fragment or a `token` query item is what a join
needs). macOS gained **Copy Web Link** beside Copy Link; the Linux and
Windows share card shows the web form as a second selectable line.
`ShareLinkFormatTests` pin both directions.

**Docs.** `platform-support.md` has the Browser column across every table,
with the honest ⚠️/❌: viewing only, guests only, relayed always, no
microphone, no zoom, cancel-while-waiting is closing the tab, Safari
untested. `usage.md` describes the browser as the third way to join,
`install.md` says there is nothing to install to watch, the landing page
mentions it.

**Firefox.** Playwright's Firefox build decodes H.264 and Opus via
WebCodecs (the probe: every H.264 profile supported, HEVC not, Opus yes),
so `PW_BROWSER=firefox make test-web-spike` runs the same assertions on a
second engine. Safari remains unrun: no headless WebKit with WebCodecs
here. "avc" + avcC is the format WebKit accepts, so it is the first thing
to check on a Mac.

**Size** stayed where Phase 2 measured it (34 MB raw, 7.8 MB gzip, 5.4 MB
brotli). The `guest` package's server half rides along because it is one
package; splitting it behind a build tag would be a fork change for a few
megabytes of raw size that the gzip transfer mostly hides. Deferred.

## Non-goals

- **Browser sharing.** `getDisplayMedia` capture + WebCodecs encode is a
  different feature with a different consent model; nothing here blocks it
  later.
- **Tailnet sign-in from the browser.** The page is guest-only: the token is
  the rendezvous. A tsconnect-style wasm tailnet node is out of scope.
- **Voice uplink from the page** (listen-only first — the mute-latch and
  consent surface deserve their own pass).
- **Automatic UDP→stream fallback for native viewers** — follow-up after
  Phase 1; the profile ships behind the env override first.

## Risks and open questions

| Risk | Standing |
| :- | :- |
| `guest` client under `GOOS=js` | **Retired** (Phase 2): compiles unchanged and bootstraps in Chromium; `linux-web-spike` pins it. |
| Relay bandwidth | Every browser viewer is DERP-relayed. Self-hosted derper guidance ships with Phase 4 docs; the sharer's per-viewer fairness already isolates a slow relay path. |
| wasm size (~27 MB class) | **Measured** (Phase 2): 33.9 MB raw, 7.8 MB gzip, 5.4 MB brotli. Budget decisions are Phase 4's, now with a real number. |
| WebCodecs variance (HEVC, Safari) | **Measured on Chrome** (Phase 3): H.264 every profile ✓, HEVC ✗ on Linux → the CODEC_NO path; Playwright's Chromium has no H.264 at all, so the gate runs on Chrome. Safari/Firefox live runs still owed (Phase 4). |
| Double-reliable stacking (our stream inside WG inside WebSocket/TCP) | Loss on the physical path recovers in the outer TCP; the inner plane sees it as delay, which is what the backpressure controller keys on. Latency under loss will be worse than native UDP — inherent, documented, and the reason native apps stay the recommendation. |
| Ordering vs. the annotation invariant | Media and annotations share one connection; frames are sent from one prioritized outbox, so the annotation-ordering rule (synchronous enqueue, one drain) carries over unchanged — the outbox must preserve enqueue order within each priority class. |
