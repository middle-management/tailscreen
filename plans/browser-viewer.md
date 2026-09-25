# Browser viewer — the stream profile, the wasm transport, and the page

> **Status: shipped.** All four phases are on `main`. The page is live at
> `https://tailscreen.dev/next/view/`; the root `/view/` (what the apps'
> **Copy Web Link** points to) appears once a stable release's tree carries
> `web/viewer/index.html` (the Pages workflow's channel rule — same as
> `docs/`). See Follow-ups for what's still open.
>
> This is the "separate plan" `plans/share-by-token.md` deferred. Feasibility
> groundwork: `plans/tailcat-evaluation.md`, "Use case 2: browser viewer".

## What ships

A guest clicks a share link and watches **in a browser tab** — no app
install, no Tailscale account. The page dials the sharer with the same
`tc…` token every native guest uses, lands in the same mandatory per-join
approval queue, and renders H.264/HEVC via WebCodecs. The sharer needs
nothing browser-specific: a browser viewer is a guest whose media rides a
new **stream profile** — the one protocol addition this work made, useful
on its own for any UDP-blocked native viewer too.

## Why the browser can't be a fourth native-style app

1. **No UDP, ever.** wasm has no datagram socket; the only path out is
   WireGuard-over-WebSocket via DERP, so every browser viewer is
   **relayed**, at full share bitrate — viable on a self-hosted derper
   (`docs/self-hosted.md`), not on the free relays.
2. **Loss recovery becomes dead weight** on a reliable stream: FEC/NACK
   parity is wasted bitrate, retransmission is redundant. What replaces
   loss is **delay**, which wants a different backpressure response, not a
   different receiver.

So the design carries the existing datagram plane over a reliable byte
stream, with loss-recovery machinery negotiated off — landing natively
first (Phase 1) so all three apps also gain a "UDP is blocked" fallback.

## The design: datagrams framed over the stream

One new TCP message type, `0x0D` `mediaDatagram` (both directions, payload
= exactly one UDP/7447 datagram, demuxed by first byte exactly as
TS-GEN-020 demuxes UDP). Spec'd in `docs/spec.md` §2.2 as
`TS-STM-0xx`; registry rows in `WireByteRegistryTests` and
`conformance/vectors/tcp-framing.json`; both enums
(`ScreenShareMessageType` and `sdk/go/tailscreen/frame.go`).

Key decisions and the why:

- **No capability bit, no negotiation message.** A viewer sends its HELLO
  itself as a `0x0D` frame; that connection *becomes* the viewer's address
  for the rest of the session (TS-GEN-012/014 read literally: "the
  connection the HELLO arrived on"). Degrades cleanly both ways — a legacy
  sharer drops unknown `0x0D` frames and the join times out; a legacy
  viewer never sends one.
- **`nack`/`fec` MUST NOT be advertised by a stream viewer**, and the
  sharer MUST NOT send retransmits/FEC to one regardless of what was
  advertised. `receiverReport` SHOULD still be advertised — loss reads
  ~0, but RR still carries jitter/RTT/liveness. PLI is unchanged: a stream
  viewer is behaviorally the legacy PLI-only viewer the protocol has
  always supported, minus packet loss.
- **Sender-side drop replaces network loss, and needed no new machinery.**
  The existing per-viewer send-chain cap already sheds whole frames when a
  slow viewer's queue backs up (a blocking TCP write backs up only its own
  chain); a shed frame keeps its reserved seq range so the viewer PLIs,
  which on this transport can only mean sender-side omission. Sustained
  pressure rides the existing fairness loop (`.isolated` → keyframe-only
  throttle). TCP-write-blocks → chain backlog → shed → PLI → fairness
  throttle is the same response path a slow UDP viewer gets today.

## What shipped, phase by phase

- **Phase 1 (native stream profile).** Spec/registry/vectors/enums; sharer
  routes `0x0D` HELLOs to a stream-viewer registration (media rides the
  TCP connection as a third leg beside `MediaSockets`); viewer wraps its
  outbound datagrams in `0x0D` frames. Forced today via
  `TAILSCREEN_FORCE_STREAM=1`; **automatic UDP→stream fallback is a known
  gap**, see Follow-ups.
- **Phase 2 (wasm transport spike).** Proved the fork's `guest` package
  compiles for `GOOS=js GOARCH=wasm` **unchanged** (magicsock's js support
  and derphttp's WebSocket dial already existed from the tailcat
  lineage) — real Chromium → wasm `guest` client → DERP-over-WebSocket
  (`cmd/localderp` stands in for the relay fleet) → WireGuard → a real
  Linux sharer in link-only mode, HELLO → parked → approved → HELLO_ACK →
  video RTP over the stream, no internet required. `make test-web-spike` /
  CI's `linux-web-spike` pin it. Measured: `viewer.wasm` 33.9 MB raw / 7.8
  MB gzip / 5.4 MB brotli (carries the whole `guest` package, server half
  included, plus sdk/go).
- **Phase 3 (the page).** `sdk/go`'s reorder buffer/depacketizers/RR
  accounting run inside the wasm, driven by the page's own clock
  (`ingest`/`tick`). Video: WebCodecs decodes H.264 as "avc" (existing
  AVCC + a built avcC description) and HEVC as Annex B; a codec reported
  unsupported latches to H.264 via the existing CODEC_NO path. Audio:
  Opus → `AudioDecoder` → `AudioContext`, listen-only. Strings come from
  the shared TailscreenL10n catalog, exported to `dist/strings.json` at
  build time — translated once, translated in the browser too.
  **Playwright's own Chromium has no proprietary codecs** (H.264/HEVC both
  report unsupported; VP8/AV1/Opus fine), so the harness prefers real
  Google Chrome when present and degrades to transport-only assertions
  otherwise.
- **Phase 4 (chrome and shipping).** Remote control and annotations are
  framed JSON on the same connection the page already holds — nothing
  changed on the sharer, since the grant gate was already connection-scoped.
  `wire.js` is the pure, browser-free-testable half (HID keycode mapping,
  §12.2/§11 JSON builders). Hosting: GitHub Pages won't compress
  `application/wasm`, so the page fetches a pre-gzipped `viewer.wasm.gz`
  and inflates with `DecompressionStream` (falls back to raw where
  missing); `make web-viewer-bundle` inlines everything into one HTML file
  for offline distribution. Links: `ShareLinkFormat.webLink` puts the
  token in the URL **fragment** so the page's host never sees it; any host
  is accepted on join since the page is static and self-hostable.
  `docs/platform-support.md` carries the Browser column with its honest
  gaps (relayed always, no mic, no zoom, Safari untested).
  Post-ship: an empty page now shows the apps' join-by-link/token field
  instead of a dead end.

## Follow-ups

- **Root `/view/` is a 404 until the next stable release** carries the
  page — `/next/view/` serves `main` meanwhile. Nothing to do but release.
- **`make web-viewer-bundle` isn't attached to release artifacts** — a
  product call, not a technical gap.
- **Safari is unrun** (no headless WebKit with WebCodecs in the harness).
  "avc"+avcC is believed to be WebKit's accepted format; check
  `DecompressionStream` (16.4+) and the audio-gesture rule at the same time.
- **Automatic UDP→stream fallback for native viewers** — still gated
  behind `TAILSCREEN_FORCE_STREAM=1`; the Phase 1 follow-up.
- **Every browser viewer is DERP-relayed** at full share bitrate — a
  direct WebRTC-data-channel or WebTransport path is the way out, and is
  a sharer-side transport change, not a page change.
- **wasm size** (34 MB raw / 7.8 MB gzip): the `guest` package's server
  half rides along because it's one package; splitting it behind a fork
  build tag would trim raw size the gzip mostly hides already. Deferred.

## Non-goals

- Browser **sharing** (`getDisplayMedia` capture) — different feature,
  different consent model.
- Tailnet sign-in from the browser — guest-only, the token is the
  rendezvous.
- Voice uplink from the page (listen-only for now).

## Risks, as they stand

| Risk | Standing |
| :- | :- |
| `guest` client under `GOOS=js` | Retired — compiles unchanged, pinned by `linux-web-spike`. |
| Relay bandwidth | Structural: every browser viewer is relayed. Self-hosted derper docs ship; sharer fairness isolates a slow relay path. |
| WebCodecs variance | Measured on Chrome + Firefox: H.264 every profile on both, HEVC ✗ on Linux → CODEC_NO. Safari unmeasured. |
| Double-reliable stacking (stream inside WG inside WebSocket/TCP) | Loss recovers in the outer TCP; inner plane sees it as delay. Latency under loss will be worse than native UDP — inherent, and why native apps stay the recommendation. |
| Ordering vs. annotations | Media and annotations share one connection via one prioritized outbox — the enqueue-order invariant carries over unchanged. |

## Where the details live

Wire-level rules: `docs/spec.md` §2.2 (`TS-STM-0xx`) and Appendix A.2
(`0x0D`). Page/build specifics: `.claude/rules/web-viewer.md`. Platform
matrix: `docs/platform-support.md`.
