# Tailscreen protocol SDK — Go

A complete implementation of the [Tailscreen wire protocol](../../docs/spec.md)'s
codec layer and receiver-side pipeline, usable from Go directly or from any
language that can link a C static library.

```go
import "github.com/middle-management/tailscreen/sdk/go/tailscreen"
```

```c
#include "libtailscreen.h"   /* make libtailscreen */
```

## Why this exists

Tailscreen's apps are written in Swift. This package is a second
implementation, written from the specification and sharing no code with them,
and both are run against the same
[conformance vectors](../../conformance/README.md). That arrangement is what
turns the specification from a description into a contract: the Swift side
proves it describes what ships, and this side proves it says enough for
somebody who only read it.

Which makes this the natural thing to build a third-party client on. It is not
a demonstration that happens to be public — it is the artifact the
specification is checked against.

## Scope

It encodes, decodes, and runs the receiver-side pipeline. It owns no socket,
no goroutine and no clock — every time-driven type takes `nowNs` from the
caller, so a recorded session replays deterministically.

| In | Out |
| :- | :-- |
| UDP control plane, capability negotiation | the protocol's admission policy |
| RTP headers, H.264 / HEVC packetization | capture, encoding, decoding, rendering |
| NACK, receiver reports, RTT pings, XOR parity | congestion control and the FEC on/off gates |
| The framed TCP channel and its JSON payloads | the remote-control grant lifecycle |
| The receive pipeline: `ReorderBuffer`, `Depacketizer`, `NACKScheduler`, `FECGroupBuffer`, `RRAccounting` | the loop that drives it (bring your own) |
| The specification's constants (`Port`, `IdleTimeout`, …) | anything Tailscale |

The excluded column is normative too — it is in the specification's prose,
and the constants your implementation of it needs are exported here. The
pipeline types are pure state machines over explicit inputs; what is
deliberately absent is an event loop, so that a client can bring its own
concurrency model rather than inherit one from a protocol library.

**This package does not authenticate anything.** The protocol assumes it runs
inside a Tailscale tunnel and defines no encryption, authentication or
integrity protection of its own (TS-GEN-011). Connect the sockets through
tsnet or a host tailnet. Do not put this on an open network.

## Using it from Go

```bash
go get github.com/middle-management/tailscreen/sdk/go
```

`go doc github.com/middle-management/tailscreen/sdk/go/tailscreen` is the
reference; the package doc opens with a minimal viewer loop, and
`example_test.go` carries runnable examples for the handshake, the
demultiplex, NACK, parity recovery and the framed channel.

Two conventions worth reading before the API:

- **The byte-level codecs report failure as an `ok` boolean, not an error.**
  There is one failure mode — the datagram was malformed — and the protocol's
  answer to it is always the same: discard it silently. An error value would
  carry no information the boolean doesn't. The JSON payload decoders do
  return errors, since that is a layer where you may want to log what a peer
  sent.
- **Unknown input is not an error.** An unassigned control byte, an unassigned
  message type, an unknown capability bit and an unknown annotation tool are
  all things you discard and carry on from (TS-EXT-001). This is the whole of
  the protocol's forward compatibility, and an implementation that raises on
  them will break against the next peer that ships a feature it lacks.

## Using it from a browser

The same package compiles for `GOOS=js GOARCH=wasm` unchanged — it owns no
socket and no goroutine, which is what makes that true — and that is how
Tailscreen's own [browser viewer](../../web/viewer/README.md) is built: this
SDK plus the guest tunnel's client, one wasm module, with a page on top that
does WebCodecs and a canvas. Every wire byte the page sends or reads comes
from here, so the page never re-implements a format the conformance vectors
pin. It is also the worked example of the specification's reliable-transport
profile (§2.2): a browser has no UDP, so the page carries the datagram plane
as `MsgMediaDatagram` frames over the TCP channel, and past the demultiplexer
the pipeline is the one described above.

## Using it from C

`make libtailscreen` from the repository root produces
`sdk/go/build/libtailscreen.a` and a generated `libtailscreen.h`:

```bash
make libtailscreen
cc -Isdk/go/build app.c sdk/go/build/libtailscreen.a -lpthread -o app
```

This is the same mechanism one floor down: `libtailscale.a` is Go built with
`-buildmode=c-archive` and consumed from Swift through a `systemLibrary`
target, and this archive links the same way — from C, C++, Swift, Rust, Zig,
or anything else with a C FFI.

Two rules, both in `capi/capi.go`'s doc comment at more length:

- **You free what it returns.** Every function returning bytes returns C
  `malloc`'d memory; release it with `tailscreen_free`. A `NULL` pointer with
  length 0 means the input was rejected, which is the protocol's normal
  answer to a malformed datagram rather than an exceptional condition.
- **The stateful pieces are handle-based.** The framed-channel parser, the
  reorder buffer, the depacketizers, the NACK scheduler, the FEC group buffer
  and the receiver-report accounting each get a `*_new` / `*_free` pair whose
  handle you pass back on every call; components that can emit several
  results from one input queue them on the handle, popped one at a time by a
  `*_next_*` call. Each handle carries its own lock, time always arrives as
  an explicit `now_ns` argument, and everything else is a pure function over
  bytes — the whole library is safe to call from any thread.

`ctest/smoke.c` is a worked example as well as a test: `make
libtailscreen-check` builds and runs it. It lives outside the `capi/`
directory because cgo compiles every `.c` file in a package's own directory,
which would build it *into* the archive rather than against it.

### One Go runtime per binary — build your own archive if you need more Go

A c-archive embeds a whole Go runtime, and two of them cannot be linked into
one binary: their cgo export symbols (`crosscall2`, `_cgo_panic`,
`_cgo_topofstack`) collide at link time, and even a linker that tolerated
that would hand you two runtimes in one process, which Go does not support.
So if your application needs this SDK **and** another Go library — tsnet /
libtailscale being the obvious pairing for a Tailscreen client — do not link
two archives. Build **one** archive from your own `package main` that
imports everything you need, exactly the way Tailscreen itself builds
`libtailscale.a` from the libtailscale sources (with its own patches) rather
than consuming a prebuilt binary.

Concretely: a Go `package main` is not importable, so the `//export` shim
always lives with whoever builds the archive. Start by copying `capi/capi.go`
into your own module (it is MIT-licensed and deliberately thin — every
function is a few lines over `sdk/go/tailscreen`), add your own exports for
whatever else your binary embeds (tsnet dial/listen, for instance), and build
it with the same command the Makefile uses:

```bash
go build -buildvcs=false -buildmode=c-archive -o libmyapp.a ./mycapi
```

The same constraint is why the Swift↔Go differential suite lives in its own
package (`Packages/TailscreenDifferential`): TailscreenKit's test binary
already links `libtailscale.a`, so the suite that links `libtailscreen.a`
needs a binary of its own. (Dynamic `-buildmode=c-shared` libraries are the
one alternative — each `.so` keeps its runtime to itself — but the combined
static archive is the simpler and better-trodden path, and a pure-Go client
needs none of this: import the package and tsnet directly.)

## Testing

```bash
cd sdk/go && go test ./...     # unit tests, examples, and the fuzz seed corpus
make test-conformance          # the vectors, from the repository root
make libtailscreen-check       # the C ABI
make test-differential         # the Swift↔Go differential suite
make fuzz-conformance          # coverage-guided fuzzing, FUZZTIME=30s per target
```

The pipeline tests in this package are ported assertion-for-assertion from
the Swift suites, and `make test-differential` closes the loop from the
other side: `Packages/TailscreenDifferential` links this SDK's c-archive and
drives it against the shipping Swift pipeline with identical seeded input,
asserting identical output at every step. Which is why a behavioral change
to a ported type must land on both sides in the same commit — including the
deliberate warts (`PackFCI`'s non-wrap-aware sort): "fixing" one side alone
fails the differential, and is meant to.

The fuzz targets in `tailscreen/fuzz_test.go` assert structural invariants
rather than expected values — a successful decode never claims more bytes
than it was given, a rejection stays rejected, anything the encoder produces
the decoder reads back. Their seed corpus runs free on every `go test`; the
mutation run needs a time budget and so needs asking for. A 20-second run
found the protocol's under-specified RTP padding bit, which is TS-VID-008
now.

## Stability

The package version tracks the **specification** revision, exported as
`SpecVersion`, not the Tailscreen app's version. Wire values are permanent
(TS-EXT-003): a shipped control byte, message type, capability bit, payload
type or reserved SSRC is never renumbered or reused, so code written against
this package keeps interoperating.

The Go API itself is pre-1.0 and may still be reshaped — the wire is the
contract, the function signatures are not yet. When they settle, this section
says so and the module gets a v1 tag.
