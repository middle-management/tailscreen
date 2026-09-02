# Browser viewer — `web/viewer`

The browser viewer's Go module (`plans/browser-viewer.md`, Phases 2–4): a
browser dials a share by its `tc…` token through the guest tunnel
(WireGuard over a DERP WebSocket), elects the stream profile, and decodes
and renders it with WebCodecs — against the real sharer, with no internet.

```
main_js.go        the wasm's JS surface: dial, framing, the session factory, constants
session_js.go     the receive pipeline over sdk/go: reorder → depacketize → access units;
                  HELLO/KEEPALIVE/receiver-report/PLI cadences on the page's clock
index.html
viewer.js         the page: WebCodecs video → canvas, Opus → Web Audio, placards, HUD,
                  remote control and drawing on an overlay, the gzip-inflating loader
wire.js           the pure wire half: HID key map, input/annotation JSON, annotation store
cmd/localderp/    a DERP+STUN+/derpmap stand-in for the relay fleet (self-signed TLS)
e2e/spike.mjs     Playwright: localderp + Xvfb + `tailscreen-sharer-linux --link` + Chrome
e2e/wire.test.mjs wire.js against the spec's own examples, no browser
tools/            export_strings.py (catalog → dist/strings.json), bundle.py (one HTML file)
dist/             build output (gitignored)
```

```bash
make web-viewer        # GOOS=js GOARCH=wasm build + sizes (raw / gzip / brotli) + strings.json
make web-viewer-bundle # dist/tailscreen-viewer.html: everything inlined, for an offline network
make test-web-spike    # the whole end-to-end, Linux only (see .claude/rules/testing.md)
```

Hosted at `https://tailscreen.dev/view/` by the Pages workflow (`/next/view/`
tracks main; the root appears once a stable release carries the page). The
page fetches `viewer.wasm.gz` and inflates it itself — GitHub Pages does not
compress wasm — so first load is the gzip size, not the raw one. A share's
**web link** is that URL with the token in the fragment
(`ShareLinkFormat.webLink`), so the token never reaches the host.

The module `replace`s the fork onto the submodule checkout and the SDK onto
`../../sdk/go`, so the wasm build and the c-archive build pin the same
commits. The JS surface is deliberately tiny and documented at the top of
`main_js.go`; every wire byte comes from sdk/go, so the page never
re-implements a format the conformance vectors already pin.

The e2e wants Google Chrome (`playwright install chrome`): Playwright's own
Chromium has no H.264, so there it verifies the transport only.

What is *not* here: the microphone (listen-only), zoom and pan, and a
Safari run — Chrome, Edge and Firefox are what the harness has exercised.
Sharing from a browser is a different feature (plans/browser-viewer.md,
non-goals).
