# Tailscreen protocol conformance suite

The specification in [`docs/spec.md`](../docs/spec.md) says what an
implementation MUST do. This directory is how you find out whether one does.

```
conformance/
├── vectors/          the vectors — language-neutral JSON, one file per area
├── go/               the Go runner
└── tools/            the generator that produces vectors/
```

The implementation the Go runner drives is not in here: it is
[`sdk/go`](../sdk/go), the public Go SDK, which is a shipped artifact rather
than test scaffolding. That is the point of the arrangement — the thing a
third party would build a client on is the thing the vectors check.

Two runners execute the same files today:

| Runner | Implementation under test | How to run |
| :----- | :------------------------ | :--------- |
| Go | `sdk/go/tailscreen` — written from the spec, sharing no code with the app | `make test-conformance` |
| Swift | `Packages/TailscreenKit`'s production codecs | `make test-protocol` (`ConformanceVectorTests`) |

Two runners is the point. The Go side proves the specification is
implementable by somebody who only read it; the Swift side proves the
specification describes what Tailscreen actually ships. A vector that only
one of them passes is a bug in the spec, the vectors, or an implementation —
and which of the three it is has always been worth knowing.

## Running

```bash
make test-conformance                    # the Go suite
cd conformance/go && go test ./...       # the same thing, directly
cd conformance/go && go test -v ./...    # per-case output
```

A failure names the case, the requirement it violates, and both sides of the
comparison:

```
control/encode-hello violates TS-CTL-001
  op:   control.encodeSimple
  want: {"bytes": "00"}
  got:  {"bytes": "ff"}
```

## Vector format

Every file is one suite:

```json
{
  "suite": "udp-control",
  "description": "…",
  "spec": "docs/spec.md#4-udp-control-plane",
  "cases": [
    {
      "id": "hello-ack/decode-strict-rejects-six",
      "requirements": ["TS-CAP-004"],
      "op": "helloAck.decodeStrict",
      "in": { "bytes": "040000000207" },
      "out": { "ssrc": null }
    }
  ]
}
```

- **`id`** is stable and unique across the suite. Don't renumber one; retire
  it and add a new one.
- **`requirements`** cites the identifiers from `docs/spec.md`. Both runners
  fail a case that cites nothing, and fail a case citing an identifier the
  specification does not define — a renamed requirement can't quietly lose
  its coverage.
- **`op`** selects a dispatch entry (below). `in` and `out` are that op's
  input and expected output.
- Binary values are lowercase hex strings, `""` for empty.
- 64-bit clock values (`serverUptimeNs`, `lastPingTs`) are **decimal
  strings**: a JSON number loses precision above 2^53 and these are
  nanosecond counters.

## The dispatch table

Porting the suite to a third language means implementing these ops and
nothing else. `conformance/go/runner.go` is the reference dispatcher;
`ConformanceVectorTests.swift` is the same table in Swift.

| Op | In | Out |
| :- | :- | :-- |
| `control.encodeSimple` | `kind` | `bytes` |
| `control.decodeKind` | `bytes` | `kind` (null if unassigned) |
| `control.classify` | `bytes` | `class`: `empty` / `rtp` / `control` |
| `hello.encode` | `caps` | `bytes` |
| `hello.decodeCaps` | `bytes` | `caps` |
| `helloAck.encode` | `ssrc`, `caps` (null ⇒ plain form) | `bytes` |
| `helloAck.decodeStrict` | `bytes` | `ssrc` (null ⇒ rejected) |
| `helloAck.decodeTolerant` | `bytes` | `ssrc`, `caps` (both null ⇒ rejected) |
| `nack.encode` | `entries[]` | `bytes` |
| `nack.decode` | `bytes` | `entries[]` (empty ⇒ rejected) |
| `ping.encode` | `serverUptimeNs` | `bytes` |
| `ping.decode` | `bytes` | `serverUptimeNs` |
| `rr.encode` | `report`, `includeRecoveryFields` | `bytes` |
| `rr.decode` | `bytes` | `report` |
| `fec.encodeDatagram` | `baseSeq`, `count`, `body` | `bytes` |
| `fec.decodeDatagram` | `bytes` | `baseSeq`, `count`, `body` |
| `fec.parity` | `packets[]` | `body` (empty ⇒ degenerate group) |
| `fec.recover` | `missingSeq`, `ssrc`, `members[]`, `body` | `packet` |
| `rtp.encodeHeader` | header fields | `bytes` |
| `rtp.decodeHeader` | `bytes` | header fields + `payloadOffset`, or `header: null` |
| `packetize.h264` / `packetize.hevc` | `nals[]`, `timestamp`, `ssrc`, `startSequence` | `packets[]` |
| `frame.encode` | `type`, `payload` | `bytes` |
| `frame.parse` | `chunks[]` | `frames[]` (known types only), `corrupt` |
| `json.inputEvent.decode` | `json` | `event` |
| `json.annotationOp.decode` | `json` | `op` |
| `json.requestToShare.decode` | `json` | `fromHostname` (clamped) |
| `json.shareResponse.decode` | `json` | `accepted` |
| `json.controlRevoked.decode` | `json` | `reason` (clamped) |
| `json.metadata.decode` | `json` | `metadata` (display strings clamped) |

Two conventions worth knowing before you add a case:

- **`frame.parse` reports framing, not payloads.** Unknown message types are
  skipped (TS-TCP-003); a known type's payload comes back raw. Whether a
  payload decodes is the `json.*` ops' business. Keep the payloads in
  `tcp-framing` vectors to a single JSON key or none: the Swift runner
  re-encodes each parsed message to recover its bytes, and JSON object key
  order is not guaranteed across implementations.
- **The `json.*` ops are decode-direction only.** Encoding JSON byte-exactly
  across languages is a fight about key order and float formatting that says
  nothing about interoperability. What the vectors pin is what a receiver
  must accept, what it must reject, and what it must clamp before use.

## Regenerating the vectors

The vectors are checked in. `tools/gen_vectors.py` rebuilds them:

```bash
python3 conformance/tools/gen_vectors.py
make test-conformance    # and `make test-protocol` where Swift is available
```

The generator exists so that a bulk change — a new field, a renamed op — is
a code edit rather than a hand-edit of several thousand hex characters, and
so the long fragmentation vectors are reproducible. It is a fixture builder,
not a third implementation: nothing consults it at run time, and it is the
runners that decide whether its output is right.

## Adding a case

1. Write or amend the requirement in `docs/spec.md`, with an identifier.
2. Add the case to the matching suite in `tools/gen_vectors.py`, citing that
   identifier.
3. Regenerate, then run **both** runners.

A new wire value additionally needs a row in the specification's
[registry appendix](../docs/spec.md#appendix-a-wire-value-registry) and a row
in `WireByteRegistryTests` — three places, one commit (TS-CNF-002).

## Fuzzing

The SDK carries coverage-guided fuzz targets beside the implementation
(`sdk/go/tailscreen/fuzz_test.go`). They complement the vectors rather than
duplicating them: a vector says what a correct implementation does with input
somebody meant to send, and a fuzz target says what it does with input nobody
meant to send — which is the input that actually arrives.

```bash
make fuzz-conformance                 # every target, FUZZTIME=30s each
FUZZTIME=5m make fuzz-conformance     # longer
```

The seed corpus runs on every `go test`, so this costs the PR path nothing.
A crash is written to `sdk/go/tailscreen/testdata/fuzz/<Target>/`; commit it
and it becomes a permanent regression case. A 20-second run of
`FuzzDecodeRTPHeader` is what surfaced the RTP padding bit that no
requirement covered — TS-VID-008 exists because of it.

## What this suite does not cover

Codecs, not state machines. Timeouts, admission policy, congestion control,
the FEC on/off gates and the remote-control grant lifecycle are all normative
and none of them is a byte comparison; they live in the spec's prose and in
the suites named in `.claude/rules/testing.md`. An implementation that passes
every vector here is not thereby conformant — but one that fails any of them
is definitively not (TS-CNF-003).
