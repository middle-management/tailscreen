# Tailscreen protocol SDK — Go

A complete implementation of the [Tailscreen wire protocol](../../docs/spec.md)'s
codec layer, usable from Go directly or from any language that can link a C
static library.

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

It encodes and decodes. It owns no socket, no timer and no policy.

| In | Out |
| :- | :-- |
| UDP control plane, capability negotiation | the protocol's timers and admission policy |
| RTP headers, H.264 / HEVC packetization | capture, encoding, decoding, rendering |
| NACK, receiver reports, RTT pings, XOR parity | congestion control and the FEC on/off gates |
| The framed TCP channel and its JSON payloads | the remote-control grant lifecycle |
| The specification's constants (`Port`, `IdleTimeout`, …) | anything Tailscale |

The excluded column is normative too — it is in the specification's prose,
and the constants your implementation of it needs are exported here. What is
deliberately absent is a state machine, so that a client can bring its own
event loop and concurrency model rather than inherit one from a codec
library.

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
- **One thing is stateful, and it is handle-based.** The framed-channel parser
  cannot be a pure function — a frame arrives across an arbitrary number of
  TCP segments — so `tailscreen_parser_new` hands out a handle you pass back
  and eventually `tailscreen_parser_free`. Everything else is a pure function
  over bytes and safe to call from any thread.

`ctest/smoke.c` is a worked example as well as a test: `make
libtailscreen-check` builds and runs it. It lives outside the `capi/`
directory because cgo compiles every `.c` file in a package's own directory,
which would build it *into* the archive rather than against it.

## Testing

```bash
cd sdk/go && go test ./...     # unit tests, examples, and the fuzz seed corpus
make test-conformance          # the vectors, from the repository root
make libtailscreen-check       # the C ABI
make fuzz-conformance          # coverage-guided fuzzing, FUZZTIME=30s per target
```

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
