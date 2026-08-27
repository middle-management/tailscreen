# Tailcat evaluation — no-sign-in share and a browser viewer

> Status: evaluation only, no code committed to either use case. Read against
> tailcat at `c04c5af`. Line references are to that commit; they will drift.

[Tailcat](https://github.com/tailscale/tailcat) is Tailscale's "Tailscale
without Tailscale": the `magicsock` data plane — WireGuard tunnels, DERP
bootstrap, NAT hole-punching — with the control plane removed and connection
metadata exchanged out of band as a short token. No account, no admin rights,
no changes to the machine's routing or DNS. BSD-3, same as libtailscale.

Two things we want map onto it: **sharing to somebody who is not on your
tailnet**, and **a viewer that is just a web page**. This is what each would
actually cost.

## The blocker both sit behind: tailcat carries TCP and nothing else

The tunnel is UDP. The traffic you may put *through* the tunnel is not.

- The packet filter admits exactly one protocol, `IPProto: [ipproto.TCP]`, in
  both of the matches it builds (`tailcat.go:494`, `:504`).
- `dialer.NetstackDialUDP` is installed as
  `panic("unreachable from tailcat")` — on the server (`tailcat.go:462`) and
  again on the client (`tailcat.go:1528`).
- `Server` exposes `OnTCP`, `OnTCPForward`, `ServedTCPPorts`. There is no UDP
  counterpart, and no way to supply one.

The `AllowProxy` field's doc comment says it reports "whether a TCP **or UDP**
proxy is allowed for that target" (`tailcat.go:301`), which reads like intent
that was never wired up.

Our media path is RTP over UDP on 7447, and the whole FEC → NACK → PLI stack
exists *because* it is datagrams: `TsnetTransport` binds a UDP socket, and
`DatagramInbox` drops the **oldest** packet on overflow specifically because
holding stale RTP in front of fresh RTP is worse than losing it. None of that
has a tailcat equivalent today.

What does map cleanly is the framed TCP channel — annotations, remote control,
metadata, request-to-share. `[type:1][len:4 BE][payload:N]` over a
`tailcat.Client.DialTCPPort` conn would work as-is.

### Aside: netcat has had UDP since 1995

Worth saying plainly, because it is the strongest form of the upstream ask.
tailcat's own README opens with "act like netcat, but over Tailscale's data
plane" — and netcat's defining second mode is `nc -u`. The original Hobbit
netcat, BSD `nc`, and nmap's `ncat` all take `-u` for UDP; ncat adds
`--sctp` on top. A tool that models itself on netcat and cannot carry a
datagram is missing something its namesake shipped in its first release.

That framing matters for how the ask is received: it is not "please add a
feature for a screen-sharing app", it is "the netcat analogy is incomplete."

## Question: could our own Go module patch this, instead of a diff series?

This was the specific question, and it has three separate answers depending on
what "our own module importing the packages" means.

### A wrapper module that only imports tailcat: no

Everything the UDP change needs to touch is unexported and set *inside*
`Start()`:

| What must change | Where it lives | Reachable from outside? |
| :- | :- | :- |
| The TCP-only packet filter | `Server.buildFilter()`, unexported | no |
| `NetstackDialUDP`'s panic | set inside `Start()` | no |
| A UDP forwarder on the gVisor stack | needs `lb.ns` | no |
| The backend itself | `Server.lb *locoBackend`, unexported field of unexported type | no |

The exported surface of `Server` is `Start`, `Addr`, `Close`, `DrainTCP`,
`AddAllowedClient`, `ConnBlob`, `Status`. None of them is a seam for this.
Go gives an importing module no way to reach the rest — no subclassing, no
partial classes, no monkey-patching. Importing tailcat and writing UDP support
beside it is not a thing that can be done.

### The reflect+unsafe cheat: possible, precedented, and still not what we want

There is one exception, and tailcat itself demonstrates it. To reach netstack's
unexported `ipstack` field it does exactly this (`tailcat.go:560-570`):

```go
// TODO(bradfitz): add an exported accessor to wgengine/netstack.Impl
// upstream and delete this reflect+unsafe cheat.
func tcpipStackOf(ns *netstack.Impl) *stack.Stack {
	v := reflect.ValueOf(ns).Elem().FieldByName("ipstack")
	...
	return reflect.NewAt(v.Type(), unsafe.Pointer(v.UnsafeAddr())).Elem().Interface().(*stack.Stack)
}
```

The same trick points outward: `reflect.NewAt` on `Server`'s `lb` field, again
on `lb.sys` and `lb.ns`, then `sys.Engine.Get().SetFilter(...)` with a filter
that also admits UDP, plus a UDP forwarder registered on the stack — all after
`Start()` returns, all from our own module, no fork.

**Untested.** This container's Go is 1.24.7 and tailcat's `go.mod` requires
1.26.5, so the chain above is read off the source, not compiled. Treat it as
plausible, not proven.

Even if it compiles, it is the wrong default. Every hop is an unexported field
name in somebody else's package, load-bearing and unchecked by the compiler;
tailcat's own version of this cheat carries a `panic("... dep changed?")` for
exactly that reason, and it only has to survive `tailscale.com` bumps. Ours
would have to survive tailcat's. It is the right tool for one narrow thing we
cannot get any other way, not for a feature.

### A module with a `replace` directive: yes, and it is better than what we do for TailscaleKit

This is the real answer to the question, and the good news in it.

`Packages/TailscaleKit/Patches/` exists because of a **SwiftPM** constraint:
`Sources/` symlinks into the upstream submodule, so there is nowhere to put a
change except a `.patch` file applied over the top. That arrangement is a
workaround for a package manager that has no notion of "the same library, but
with our commit on it."

Go's module system has exactly that notion, first-class:

```go
// go.mod
require github.com/tailscale/tailcat v0.0.0-...

replace github.com/tailscale/tailcat => ./third_party/tailcat
```

So the diff lives as **ordinary commits on a fork branch**, not as a patch
series. That is strictly better along every axis we care about: it is
`git rebase` rather than re-rolling a `.patch` when upstream moves, the fork
builds and tests on its own, the change is already in the shape a pull request
wants, and a rebase conflict is a merge conflict in a normal file instead of a
patch that silently stops applying.

Concretely: fork tailcat, add `OnUDP` / `ServedUDPPorts` / a UDP filter match /
a real `NetstackDialUDP` as one commit, `replace` to it, and open that same
commit upstream. If it lands, the `replace` line is deleted and nothing else
changes. If it does not, we carry a fork that rebases cleanly — which is a
better position than `Patches/` puts us in today.

**Do not** apply the TailscaleKit pattern here out of consistency. The patch
series is a scar from SwiftPM, not a house style.

### An upstream-shaped version of the change

Worth writing the fork commit as the thing we would want merged rather than
the smallest thing that unblocks us:

- `Server.OnUDP func(port uint16) (handler func(net.Conn))`, mirroring `OnTCP`.
- `Server.ServedUDPPorts []filter.PortRange`, mirroring `ServedTCPPorts`.
- A second `filter.Match` for `ipproto.UDP`, gated the same way.
- A real `NetstackDialUDP` in place of the panic, and `Client.DialUDPPort`.
- `--serve=udp:7447` in the CLI, and `-u` on the client side, because that is
  the netcat spelling and the README already promises netcat.

Filing #4-adjacent, but distinct: the three open issues are #7 (multi-region),
#5 (C bindings), #4 (web build + WebRTC). Nothing covers UDP. #5 is separately
interesting to us — see the c-archive problem below.

## Use case 1: no-sign-in share

Architecturally this is what tailcat is *for*, and several details fit better
than expected:

- **Ephemeral key per run is the default.** The token is derived from the
  server's WireGuard key; a fresh in-memory key per run means the address dies
  with the process. That is precisely the lifetime a one-off share link should
  have, and it is the default rather than something we have to enforce.
- **`AllowedClients` / `AddAllowedClient` gate on the client's node key.** This
  is a *stronger* identity than what admission keys on today — peer tailnet
  source IP (`docs/security.md:98`). A client whose key is not allowed is
  silently ignored: it cannot reach the service or learn one is running. That
  composes with the existing approval gate rather than replacing it (the same
  way ACLs do today: the key decides who can knock, the gate decides who gets
  in).
- **Bring-your-own DERP is first-class** — `--region=derp.example.com`,
  `--derpmap-url`, or a genkey-time `--fixed-region`. We already ship
  `docs/self-hosted.md`. We would want this: the free relays are rate-limited,
  and a relayed fallback carries full screen-share bitrate.

### One token, many viewers — yes, with an eviction gap

A tailcat server is genuinely multi-client, not a one-shot pipe. `locoBackend`
holds `clients map[key.NodePublic]*tailcfg.Node`, and each `meow` handshake from
a new key allocates the next node ID (`id := len(b.clients) + 2` — "server is ID
1, clients are IDs 2, 3, ..."), rebuilds the netmap with every client in it, and
hands it to magicsock (`tailcat.go:1240-1300`). One token, N simultaneous
clients, exactly the shape a share needs: the token is derived from the
*server's* key, so every viewer pastes the same string.

Better still, viewers stay individually distinguishable. Each client is given an
address derived from its own node key — `tcAddrForKey`, folding 80 bits of the
key into Tailscale's `fd7a:115c:a1e0::/48` ULA — and that address is installed
as the peer's `AllowedIPs`, so WireGuard itself enforces the binding. Our
per-viewer admission keys on peer source IP today (`docs/security.md:98`) and
that logic would carry over unchanged. One caveat: the address is a lossy
80-bit projection of the key, so anything we *persist* — a remembered approval,
a block list — should store the node key, not the derived IP.

The gap is **eviction**. There is no `delete(` anywhere in tailcat:
`b.clients` and `allowedClients` are both append-only, and `AddAllowedClient`
has no counterpart that removes. Two consequences:

- **"Drop this viewer" stays an app-layer action.** `plans/platform-alignment.md`
  holds that dropping a viewer mid-share is a decision that must exist on every
  platform that can share at all. Under tailcat we can close the framed TCP
  channel and stop sending RTP, but the peer stays in the netmap and can
  re-handshake; the tunnel-layer gate only ever tightens for *future* keys, not
  the one already in. That is not a regression — the approval gate is app-layer
  today too — but it does mean tailcat's key gate cannot be the whole story, and
  a `RemoveAllowedClient` is the second thing to send upstream after UDP.
- **The client map grows for the process lifetime.** A long share with viewers
  joining and leaving accumulates peers, and each join rebuilds and re-sorts the
  full netmap. Fine at meeting scale, worth knowing before anyone leaves a
  sharer up all day. It also means node IDs would collide if removal were ever
  bolted on naively, since they are derived from `len(b.clients)`.

One thing that is *not* different from today: fan-out is still N unicast
tunnels, so the sharer encodes once but encrypts and uploads per viewer. That is
already true over tsnet. What changes is how often a relay sits in the path —
usually not, after hole-punching, but always for browser viewers.

### What it costs

**The hub has no analogue.** `TailscalePeerDiscovery` and the `tailscreen-…`
hostname prefix give the peer list its contents; tailcat has no directory at
all, only tokens. A no-sign-in share is therefore a **second entry path beside
the peer list**, not a replacement for it — a token you paste, on both sides.
The consent model survives intact (request-to-share already exists as the "let
me in" flow), but the hub UI is built around enumerating peers and would need a
genuinely different surface.

**The c-archive question — smaller than it first looks.** The rule that two Go
c-archives cannot share one binary is real (it is why
`Packages/TailscreenDifferential` is a separate package), but it only bites if
tailcat is built as *its own* archive alongside `libtailscale.a`. Nothing forces
that: as an ordinary Go module dependency of whichever module already builds an
archive, tailcat is just more Go in the same archive, and the collision never
happens. They share the `tailscale.com` dependency tree, so there is not even a
version conflict to resolve.

What that exposes is the actual question, which is not about tailcat at all:
**who owns the module that builds our archive.** Today it is upstream
libtailscale, consumed as a submodule with symlinked `Sources/` and 26 files in
`Patches/`. Adding anything to that archive means adding a patch. See
[Who owns the archive](#who-owns-the-archive) below — it is the decision
everything else in this document turns out to hang off. (tailcat #5, "Add C
bindings", is upstream reaching at the same problem from the other side.)

**Toolchain floor — a CI-image problem, not a contributor problem.** tailcat's
`go.mod` says `go 1.26.5` against our documented Go 1.21+ floor, but on a stock
upstream Go this resolves itself: `GOTOOLCHAIN` defaults to `auto`, so the go
command downloads and re-execs the required toolchain. Verified on this
container — Go 1.24.7 against a `go 1.26.5` module printed
`go: downloading go1.26.5 (linux/amd64)` and built without a flag or a prompt.
A dependency's `go` line propagates the same way, with `go get` bumping the main
module's line to match.

Where it does *not* resolve itself is our CI. Most jobs in `build.yml` and
`app-linux.yml` install Go as `golang-go` from apt, and
[Debian patches the `GOTOOLCHAIN` default from `auto` to `path`](https://groups.google.com/g/linux.debian.bugs.dist/c/LNPCmBbxlSo)
— it will use a `goX.Y` binary already in `PATH` but will never download one,
because fetching binaries from the network at build time is against policy. So
those jobs get a hard error rather than a silent upgrade, and noble's apt Go is
1.22.

The fix already exists and is one line: `.github/actions/bootstrap` takes
`go: setup-go`, which installs via `actions/setup-go` reading the version out of
a `go.mod`. `build.yml:983` and `app-linux.yml:193` already do exactly this for
the job whose apt Go could not parse libtailscale's `go.mod`. Any job that
builds a tailcat-linked archive flips to `setup-go` the same way; jobs that
don't touch Go at all are unaffected. `CLAUDE.md`'s "Go 1.21+" line would want
updating in the same commit.

## Use case 2: browser viewer

The more valuable of the two, and cheaper than it looks — but it needs a
protocol decision first, and that decision is worth making regardless.

**The transport already exists.** tailcat's js/wasm build exports
`tailcatListen` and `tailcatDial` to JS (`web/main_js.go:29-31`), returning conn
objects with `read` / `write` / `closeWrite` / `close`. That is an encrypted
peer-to-peer transport in an unmodified browser, with no plugin and no
signalling server of our own.

**The pipeline is already written, in the right language.** `sdk/go/tailscreen`
"owns no socket, no goroutine and no clock — every time-driven type takes
`nowNs` from the caller." That is already WASM-shaped, by accident of having
been written for determinism. Compile `sdk/go/tailscreen` and tailcat into one
js/wasm binary, feed it bytes from `tailcatDial`, hand access units to
WebCodecs `VideoDecoder` (H.264 and HEVC) and Opus for audio. Reorder,
depacketize, FEC group solving, RR accounting, the framed TCP channel and its
JSON payloads all come along.

And because it is the SDK, the browser viewer is checked by the same
conformance vectors as everything else. A third implementation validated by the
existing contract, rather than a third implementation to keep honest by hand.

### What has to change first

**Browsers are DERP-relay-only, permanently for now.** js/wasm has no UDP at
all, so the browser can never hole-punch; `pickregion_js.go:15` and the
`advertiseEndpoints` comment at `tailcat.go:1093` both note that endpoint
advertisement is a no-op in a browser. Direct paths wait on WebRTC (#4). Every
browser viewer's stream is relayed, at full screen-share bitrate. On our own
derper that is a capacity question we control; on the free relays it is not
viable.

**A UDP-patched tailcat would not help here.** The browser cannot do datagrams
regardless of what the library exposes. A browser viewer needs a **reliable
transport profile**: RTP framed over the stream, FEC/NACK/PLI off (the
transport under it does not lose packets, so loss recovery is dead weight and
its retransmit logic is actively wrong), and the jitter buffer retuned for
head-of-line blocking instead of jitter.

That is a `docs/spec.md` change plus a conformance vector, not plumbing — and
it earns its keep on its own: the same profile is the fallback for any viewer
on a network that blocks UDP, on any platform.

**Binary weight.** The published web demo is ~27 MB of wasm, served gzipped
only, and their Pages workflow deletes the uncompressed copy because GitHub
Pages will not compress `application/wasm` itself
(`.github/workflows/webdemo-pages.yml`). Our build would be that plus
`sdk/go/tailscreen`. That is a real first-load cost to design around, not a
rounding error.

## Who owns the archive

tailcat is thin. It is ~2,050 lines of non-test Go outside its SSH server
(`tailcat.go` 1818, `wire.go` 111, `disco.go` 67, `pickregion.go` 55; the
436-line `tailcat_ssh.go` we would never want), sitting on 25 `tailscale.com`
packages — `wgengine`, `magicsock` via `wgengine`, `netstack`, `filter`,
`tsd`, `netmap`, `netcheck`, `tsdial`, `disco`, `tailcfg` and friends. Every
one of them is publicly importable, and every one is already inside the
dependency tree we ship in `libtailscale.a`.

So "port the parts we need" is a fair description of the size of the thing. It
also dissolves both problems this document has been circling: there is no
upstream to patch for UDP, because we would be writing the `filter.Match`
ourselves and can simply put `ipproto.UDP` in it; and there is no second
archive, because our code compiles into whichever archive we already build.

The novel parts are small and legible. The entire rendezvous protocol that
replaces the control plane is `disco.go`, 67 lines: a 4-byte `meow` magic, a
one-byte type, and two raw public keys, sent as unframed DERP packets.
`wire.go` is a CBOR token with deliberately short field names, upstream noting
they "are the wire format: do not change or reuse them" and pinning them with
`TestWireFieldNames` — the same discipline as our `WireByteRegistryTests`. And
the one genuinely cursed thing in tailcat, the `reflect`+`unsafe` reach into
netstack's unexported `ipstack` field, turns out to be load-bearing for exactly
one function: `DrainTCP`, a graceful-shutdown nicety (`tailcat.go:545`). A port
that skips `DrainTCP` inherits none of it.

### Why vendor rather than rewrite

All of which argues for taking the code, not retyping it.

The ~2,050 lines are not 2,050 lines of *our* problem domain. The bulk of
`tailcat.go` is assembling a working `wgengine` + `magicsock` + `netstack` with
a **synthesised netmap** — no control plane ever hands it one — with addresses
derived from key hashes, a hand-built packet filter, disco key plumbing and
endpoint advertisement over DERP. That is the part most likely to be subtly
wrong in a rewrite, in ways that present as "works on my LAN, fails behind
CGNAT", and it is written by the people who own magicsock.

The cost of taking it is that `tailscale.com`'s non-tsnet packages carry no API
stability promise. But we do not escape that by rewriting — a port depends on
exactly the same 25 packages and breaks on exactly the same churn, except then
nobody upstream is running CI against our version of it. Vendoring keeps a git
history to rebase and a `TestWireFieldNames` that fails loudly; a rewrite keeps
neither.

The honest summary: porting buys us nothing that vendoring under our own module
does not, and costs us the provenance.

### The decision underneath

`Patches/` is 26 files, and reading the list is the argument. Patches 013
through 020 are one feature — `ListenPacket`, which is to say **UDP** — added
across a tsnet Go file, a C header, C glue, a close path, and a Swift wrapper.
Five patches to get a datagram out of a library that did not want to give us
one. That is precisely the shape of the tailcat UDP work, and we have already
paid for it once and are still carrying it.

So the fork-in-the-road is not "tailcat or a port". It is:

- **Keep the archive upstream's.** Everything new arrives as patch 027, 028,
  029. Cheap today, and the series only grows.
- **Own a first-party Go module that builds the archive**, importing
  `tailscale.com/tsnet`, a vendored tailcat, and eventually `sdk/go`, exporting
  the C surface we actually want. Then the UDP change is a line of our own
  code, the browser viewer's wasm build is a second target of the same module,
  and `Patches/` stops growing — the 26 that encode real upstream fixes stay
  until they are upstreamed or absorbed.

The second is more work up front and is the direction every item in this
document points at. It is also a much larger change than either use case here
justifies on its own, so it should be decided on its own merits, not smuggled
in under a screen-sharing feature.

## Recommendation

In order. The first two do not depend on each other, and neither depends on
resolving the archive question.

1. **File the UDP issue upstream on tailcat**, framed as the netcat gap. It
   costs an issue, the patch is small, and it is plausibly something they want
   independent of us. If it lands, whatever we vendor needs no local change at
   all — so this is worth doing first precisely because it might make later
   steps cheaper.

2. **Specify the reliable-transport profile** in `docs/spec.md` with a
   conformance vector. This is the actual prerequisite for a browser viewer,
   it is useful with no tailcat involvement at all as a fallback for viewers on
   UDP-blocking networks, and it is the one piece nobody upstream can do for us.

3. **Browser viewer** is the better prize. `sdk/go` doing the hard part changes
   the estimate substantially — most of the remaining work is the profile in
   (2), a WebCodecs shim, and the wasm size budget.

4. **No-sign-in share** is architecturally the cleanest match to what tailcat
   is. Its real cost is not the transport but the hub: a token-shaped entry
   path in a UI built around enumerating peers.

Two findings that outlive whichever of those we do:

**Vendor, do not rewrite.** A port depends on the same 25 unstable
`tailscale.com` packages as the vendored original and breaks on the same churn,
minus the provenance and minus upstream's CI. If tailcat source ends up in our
tree it should arrive as commits on a fork under a `replace` directive — Go has
first-class support for the thing `Patches/` exists to work around, and that
series is a SwiftPM scar, not a house style.

**The archive question is the real one.** UDP, the browser wasm target and the
patch series are three faces of "libtailscale's module builds our archive, so
everything we add is a patch to somebody else's library." That is worth
deciding deliberately and on its own merits — not as a rider on a screen-sharing
feature.
