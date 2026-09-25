# Tailcat evaluation — no-sign-in share and a browser viewer

> Status: evaluation, concluded. No code dependency on tailcat exists or is
> planned; findings fed into `plans/share-by-token.md` (implemented as our own
> `guest` package, not a tailcat import) and `plans/browser-viewer.md`. Read
> against tailcat at `c04c5af`; line refs will drift.

[Tailcat](https://github.com/tailscale/tailcat) is Tailscale's data plane
(magicsock, DERP, NAT traversal) with the control plane stripped out and
connection metadata exchanged as a short token — no account, no admin rights.
BSD-3, same as libtailscale. Two things we wanted to map onto it: sharing to
someone off your tailnet, and a browser-only viewer.

## Verdict: buildable, but not by importing tailcat directly

Confirmed by running (not reading) tailcat's e2e suite against a bumped
`tailscale.com v1.102.3`: DERP bootstrap, disco handshake, direct-path
upgrade, WireGuard handshake, TCP payload delivery all pass with no control
plane involved. libtailscale itself bumps clean to v1.102.3 (`go build`,
`vet`, `test`, c-archive all green; our UDP patches' exports survive).

**Blocking finding: tailcat carries TCP only.** Its packet filter admits only
`ipproto.TCP`; `NetstackDialUDP` is a hardcoded panic on both client and
server; `Server` exposes `OnTCP`/`ServedTCPPorts` with no UDP counterpart.
Our media path is RTP/UDP, so tailcat as published cannot carry it — only the
framed TCP control channel maps over cleanly. Filed as worth raising upstream
(the netcat analogy tailcat's own README uses already implies `-u`).

**Could our module patch this without a fork?** No for a pure importer —
everything needed (`buildFilter`, `NetstackDialUDP`, the netstack backend) is
unexported inside `Start()`. A `reflect`+`unsafe` reach is possible (tailcat
itself does this for one field) but untested and the wrong default: unstable
across tailcat's own internal renames. A `replace`-directive fork (Go's
first-class version of what `Packages/TailscaleKit/Patches/` fakes for
SwiftPM) is the clean answer if we ever vendor tailcat — **do not** import
`Patches/`'s patch-series pattern here out of consistency; it's a SwiftPM
scar, not a house style.

**One token, many viewers**: works by construction — each client gets an
address derived from its node key, installed as WireGuard `AllowedIPs`, so
the tunnel itself enforces per-viewer identity (stronger than today's
peer-IP-based admission gate). Gap: tailcat has no eviction primitive
(`b.clients`/`allowedClients` are append-only) — dropping a viewer must stay
an app-layer action regardless, consistent with how approval already works.

## Who owns the archive

The recurring blocker across every finding above: our `tailscale.com`
dependency arrives via `Packages/TailscaleKit`'s submodule (pinned commit,
`Patches/` applied over symlinked sources), and Go's module system has no way
to express "same library, our commit" against a pinned submodule — a version
bump's `go.mod`/`go.sum` diff has nowhere in our repo to live. This is not
tailcat-specific: it's the same wall UDP support, a `tailscale.com` bump, and
a browser wasm target would all hit. tailcat itself is thin (~2,050 lines
outside its SSH server) sitting on 25 already-vendored `tailscale.com`
packages — cheap to vendor under our own module if we ever need it, and
strictly better to vendor than reimplement (a rewrite depends on the same
unstable packages, minus upstream's own CI coverage and provenance).

The real fork in the road, not resolved here: keep growing the upstream
patch series (cheap per-change, unbounded growth) vs. own a first-party Go
module that builds the c-archive ourselves (`tsnet` + vendored tailcat +
`sdk/go`), so future wire additions are our own code rather than another
patch. Left as a decision to make on its own merits, not smuggled in under a
screen-share feature.

## Use case 2: browser viewer

The more valuable use case, and cheaper than expected — but gated on a
protocol decision, not on tailcat. tailcat's js/wasm build already exports a
peer-to-peer transport to JS with no plugin or signalling server, and
`sdk/go/tailscreen` was already written parameter-clock-free (no owned
socket/goroutine), i.e. WASM-shaped by construction — a real path to a third,
conformance-vector-validated implementation of the protocol.

What has to happen first: browsers are DERP-relay-only permanently (js/wasm
has no UDP, so no hole-punching — direct paths wait on WebRTC), and a relayed
stream needs a **reliable-transport profile** — RTP framed over a stream,
FEC/NACK/PLI switched off, jitter buffer retuned for head-of-line blocking —
specified in `docs/spec.md` with a conformance vector. That profile is useful
independent of any browser work, as a fallback for any viewer on a
UDP-blocking network. Binary weight (~27MB wasm, gzip-only) is a real
first-load cost to design around.

## Other findings worth keeping

- **CI toolchain**: tailcat/libtailscale's `go.mod` floors are already above
  our documented Go 1.21+ and above Debian/Ubuntu's apt Go (which patches
  `GOTOOLCHAIN` from `auto` to `path`, so it never auto-downloads). Already
  solved the same way in `build.yml`/`app-linux.yml` via `.github/actions/bootstrap`'s
  `go: setup-go` — any future Go-archive job reuses that, not apt Go.
- **Bring-your-own DERP** (tailcat's `--region`/`--derpmap-url`/`--fixed-region`)
  is first-class and matters regardless of tailcat: free relays are
  rate-limited and a relayed screen-share needs full bitrate; we already
  document self-hosting (`docs/self-hosted.md`).
- **Why vendor, not reimplement**, if we ever take tailcat's code: a
  from-scratch port depends on the same 25 unstable `tailscale.com` packages
  and breaks on the same upstream churn, minus tailcat's own CI catching it
  first and minus git history to rebase against.

## Open items / not pursued

- UDP-in-tailcat issue not filed upstream.
- Reliable-transport profile not yet specified in `docs/spec.md`.
- No first-party Go module owning the c-archive; libtailscale bump not
  landed (still v1.94.1; v1.102.3 unlocks `SetPeerConfigFunc` /
  `SetPeerByIPPacketFunc`, the seams a control-plane-free backend needs).
- Swift half of a `tailscale.com` bump untested (no Swift toolchain used for
  this evaluation).
- Share-by-token shipped via a separate `guest` package (see
  `plans/share-by-token.md`) rather than by importing tailcat; this doc's
  eviction/identity/archive findings informed that design but the code paths
  are independent.
