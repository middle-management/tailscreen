# Browser viewer — `web/viewer`

The browser viewer's Go module (`plans/browser-viewer.md`, Phases 2–3): a
browser dials a share by its `tc…` token through the guest tunnel
(WireGuard over a DERP WebSocket), elects the stream profile, and decodes
and renders it with WebCodecs — against the real sharer, with no internet.

```
main_js.go        the wasm core: the fork's `guest` client + sdk/go, exported to JS
session_js.go     the receive pipeline (reorder → depacketize → AUs; keepalive/RR/PLI cadences)
index.html
viewer.js         the viewer: WebCodecs video → canvas, Opus audio, placards, stats HUD
tools/            export_strings.py: the catalog keys in strings.txt → dist/strings.json
cmd/localderp/    a DERP+STUN+/derpmap stand-in for the relay fleet (self-signed TLS)
e2e/spike.mjs     Playwright: localderp + Xvfb + `tailscreen-sharer-linux --link` + Chrome
dist/             build output (gitignored): viewer.wasm, wasm_exec.js, strings.json, localderp
```

```bash
make web-viewer        # GOOS=js GOARCH=wasm build + sizes (raw / gzip / brotli)
make test-web-spike    # the whole end-to-end, Linux only (see .claude/rules/testing.md)
```

The module `replace`s the fork onto the submodule checkout and the SDK onto
`../../sdk/go`, so the wasm build and the c-archive build pin the same
commits. The JS surface is deliberately tiny and documented at the top of
`main_js.go`; every wire byte comes from sdk/go, so the page never
re-implements a format the conformance vectors already pin.

The e2e wants Google Chrome (`playwright install chrome`): Playwright's own
Chromium has no H.264, so there it verifies the transport only.

What is *not* here yet: annotations and remote control from the page, the
microphone, hosting — Phase 4.
