# Browser viewer — `web/viewer`

The browser viewer's Go module. Phase 2 of `plans/browser-viewer.md`: the
transport only. It proves a browser can dial a share by its `tc…` token
through the guest tunnel (WireGuard over a DERP WebSocket) and move the
stream profile's framed datagrams both ways — against the real sharer, with
no internet.

```
main_js.go        the wasm core: the fork's `guest` client + sdk/go, exported to JS
index.html
viewer.js         the spike page: dial → HELLO as a mediaDatagram frame → count what comes back
cmd/localderp/    a DERP+STUN+/derpmap stand-in for the relay fleet (self-signed TLS)
e2e/spike.mjs     Playwright: localderp + Xvfb + `tailscreen-sharer-linux --link` + Chromium
dist/             build output (gitignored): viewer.wasm, wasm_exec.js, localderp
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

What is *not* here yet: decoding (WebCodecs — Phase 3), receiver reports
from the page, any UI beyond a status readout.
