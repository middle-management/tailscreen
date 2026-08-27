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

### What it costs

**The hub has no analogue.** `TailscalePeerDiscovery` and the `tailscreen-…`
hostname prefix give the peer list its contents; tailcat has no directory at
all, only tokens. A no-sign-in share is therefore a **second entry path beside
the peer list**, not a replacement for it — a token you paste, on both sides.
The consent model survives intact (request-to-share already exists as the "let
me in" flow), but the hub UI is built around enumerating peers and would need a
genuinely different surface.

**Two Go c-archives cannot share one binary.** This repo already knows this —
it is why `Packages/TailscreenDifferential` is a separate package. tailcat is a
Go library importing `tailscale.com`, so `libtailscale.a` plus a `libtailcat.a`
in one app binary hits exactly that wall. The fix is one c-archive exporting
both bridges from a single Go module, which is feasible because they share the
`tailscale.com` dependency tree — but it is real surgery on how TailscaleKit is
built, and it is the largest single line item in this use case. (tailcat #5,
"Add C bindings", is upstream reaching for the same thing from the other side;
worth watching or contributing to rather than solving privately.)

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

## Recommendation

In order, and the first two do not depend on each other:

1. **File the UDP issue upstream on tailcat**, framed as the netcat gap. Both
   use cases sit behind it, the patch is small, and it is plausibly something
   they want independent of us. Open the fork commit alongside it.

2. **Specify the reliable-transport profile** in `docs/spec.md` with a
   conformance vector. This is the actual prerequisite for a browser viewer,
   it is useful without tailcat at all as a UDP-blocked fallback, and it is
   the piece nobody else can do for us.

3. **Browser viewer** is the better prize. `sdk/go` doing the hard part
   changes the estimate substantially — most of the work is the profile in (2),
   a WebCodecs shim, and the wasm size budget.

4. **No-sign-in share** is architecturally the cleanest match to what tailcat
   is, but it is the bigger lift: the c-archive collision and a token-shaped
   entry path in a hub built around peer enumeration are both larger than
   anything in (3).

If a fork happens, it lives under a `replace` directive as commits, not as a
`Patches/` series. That distinction is the main portable finding here.
