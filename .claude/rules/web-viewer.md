---
paths:
  - "web/viewer/**"
---

# Browser viewer (`web/viewer`)

A static page that watches a share from a browser tab: the fork's `guest` client + `sdk/go` compiled to js/wasm, WebCodecs for decode, a canvas to draw on, Web Audio for sound. It only *views*, only as a **guest** (share-link token in the URL fragment), and — because a browser has no UDP — only over the **stream profile** (spec §2.2): HELLO goes out as a `mediaDatagram` frame and the whole datagram plane rides TCP from then on. Design/history: `plans/browser-viewer.md`; file map: the module's own README.

## Three layers

- **`main_js.go` / `session_js.go` — the wasm.** Dial, §10 framing, HELLO/control builders, `tailscreenNewSession()` (reorder → depacketize → access units, KEEPALIVE/RR/PLI cadence), `tailscreenDecodeMetadata`, `tailscreenConstants`. **Every wire byte comes from `sdk/go`** — never re-implement a format in JS or hard-code a type byte/PT/interval; read it off `tailscreenConstants` and add a key there when needed.
- **`wire.js` — the pure wire half.** `KeyboardEvent.code`→HID (TS-RMT-022), modifier bits (TS-RMT-023), §12.2 input/§11 annotation JSON builders, `AnnotationStore`, `tokenFromInput` (mirrors `ShareLinkFormat.token(fromUserInput:)` rule for rule — **change both or neither**, keep `wire.test.mjs` and `ShareLinkFormatTests` on the same cases). No DOM/wasm, so `e2e/wire.test.mjs` runs it in plain Node.
- **`viewer.js` — the page.** Loader, loop, `VideoPath` (WebCodecs→canvas), `AudioPath` (Opus→`AudioContext`), placards/HUD, join field, draw/control modes, `applyCaps`. `window.__viewer` is **the e2e's contract** (`state`, `rtpVideo`, `decodedFrames`, `serverCaps`, `controlling`, …) — renaming/dropping a field is an e2e change, not a refactor.

## Rules

- **New user-facing string = three edits, not one.** Add it to `tools/strings.txt` and to TailscreenL10n's catalog (every language) — `make test-l10n` does **not** scan this page. A key only this page uses (e.g. the audio button's four states) needs a **third** edit: `LocalizationCatalogTests.keysWithoutASwiftCallSite`, or the orphan check flags it for deletion. Missing key at runtime renders as the English key, silently.
- **Capability-gated UI is hidden, not disabled** — Request Control only when HELLO_ACK carries `remoteControl`, drawing tools only with `annotations`. Never show a button that sends a frame the sharer would drop.
- **No UDP fallback, no NACK/FEC (TS-STM-005).** Loss shows as delay; a stall is a keyframe request away (`session.requestKeyframe()`), never a reason to add recovery logic here.
- **Stroke width is in points against a 1000-px short edge** (TS-ANN-005; `Annotation.defaultWidth`=3, `referenceShortEdge`=1000), never a frame fraction — shipped wrong once (0.004 on the page's own canvas → a hairline everywhere else). `wire.js` owns the unit; `wire.test.mjs` pins it against the conformance vector byte for byte (the e2e can't see this — a headless sharer draws nothing).
- **WebCodecs needs a secure context** (`https://` or `file://`) — `VideoDecoder` is undefined over plain `http://` from a non-localhost host; keep the placard saying so.
- **H.264 goes in as `avc`+avcC built from in-band SPS/PPS; HEVC as Annex B + `hev1.…`.** When `isConfigSupported` says no, call `session.codecUnsupported()` (CODEC_NO) — don't transcode in JS.
- **The wasm is fetched gzipped and inflated in the page** (`DecompressionStream`) because GitHub Pages won't compress `application/wasm` (34MB raw vs 7.8MB gz). The single-file bundle (`tools/bundle.py`) inlines the same gzip as base64. A new file the page loads must be added to `pages.yml`'s `publish()` list AND to `bundle.py`, or it 404s on the site only.
- **Hosting has a channel rule:** `/next/view/` tracks `main`; root `/view/` publishes only from the latest stable release tag (`.claude/rules/ci.md` → Pages).
- **`go.mod` `replace`s** pin the fork submodule + `../../sdk/go` — bumping the submodule pointer changes what the page dials.

## Audio has its own check

The headless e2e sharer sends no audio, so `e2e/audio.test.mjs` feeds real Opus (`e2e/gen_opus.py`, libopus via ctypes) straight into `AudioPath` in a real browser: decode, scheduling, per-type counters (`audioVoice`/`audioSystem`, PT 98 at SSRC 0 must decode like PT 99), no play errors, and (Chromium only — headless Firefox stays suspended by design) a running `AudioContext`. The failure that looks like nothing is a **suspended context**: packets tick, decoder runs, no sound — the HUD's `ctx` line shows it, and any pointer/key resumes it. HUD's `rtp` counter is pre-gate (enabled/muted); everything after it is post-gate.

## The e2e, and its traps

`make test-web-spike` (Linux; `linux-web-spike`): `e2e/wire.test.mjs` → build `cmd/localderp` + `tailscreen-sharer-linux` → `e2e/spike.mjs` (Xvfb → link-only sharer `--link --link-relay-map-url … --approve-guests --allow-control --grant-control` → real browser) asserting `acked`, ≥50 video datagrams, ≥10 decoded frames non-flat, a pointer move landing via `xdotool`, drawing tools hidden. Knobs/flags: `.claude/rules/testing.md`.

- **Playwright's bundled Chromium has no H.264** — decode assertions downgrade to transport-only. Use Google Chrome (`playwright install --with-deps chrome`; `PW_CHANNEL` overrides, CI installs it) or `PW_BROWSER=firefox` (decodes H.264). Safari unrun.
- **The sharer's `GuestServerNode` must be retained for the life of the share** — letting it go after `token()` closes the DERP connection and the browser's bootstrap hangs with nothing in either log.
- **A container's `HTTPS_PROXY` captures loopback `wss://`** — the harness strips proxy env and launches with `--no-proxy-server`, or the page's TLS fails against localderp's cert and looks like a relay outage.
- **`deepStrictEqual` across realms fails** on objects that crossed from the page — compare via `JSON.parse(JSON.stringify(v))`.
- **`NODE_PATH="$(npm root -g)"`** finds the global `playwright` module (the Makefile sets it; a bare `node e2e/spike.mjs` doesn't).
- **`--approve-guests`/`--grant-control` are automation-only** (guest-side twins of `TAILSCREEN_OPEN_DOOR`) — never for a share with a person watching.
