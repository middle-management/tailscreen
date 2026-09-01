# Hardening & test armor: wire-byte registry, parser fuzzing, and closing known gaps

> Status: implemented (verified against the tree 2026-08-06). All ten steps
> below landed: `WireByteRegistryTests` + its seams (`CaseIterable` on the
> four wire enums, `RTPHeader.firstViewerSSRC`, `PickerHelperFraming`),
> `ParserFuzzTests` with the `decodeParameterSets` internal seam,
> `RRAccounting` (now in TailscreenProtocol) + `RRAccountingTests`, the
> NACK wraparound cases, the NaN/Infinity pinning (incl. the NaN-safe
> `RemoteControlMapping.globalPoint`), `RemoteControlDefaults` +
> `AppState.allowControlRequests` + the Settings toggle, the panic-hotkey
> grant-scoped lifecycle, the `build-release` job + diff-coverage gate in
> `build.yml` + `soak.yml`/`SoakTests`, and the test bookkeeping (now the
> `test-catalog` skill). Kept for the rationale and the file map.

## Problem & motivation

Three near-collisions of protocol byte values happened across concurrent PRs in recent
iterations:

1. **PROFILE_NO vs HELLO_DENY** — the 10-bit/HDR branch initially assigned PROFILE_NO `0x08`
   while the viewer-consent branch took `0x08` for HELLO_DENY; PROFILE_NO had to be renumbered
   to `0x09` (now `Sources/RTPPacket.swift:70`) during integration.
2. **setFrameInterval vs setAudioEnabled** — the fps-ladder branch initially assigned the
   helper-wire `setFrameInterval` command `0x04` while the system-audio branch took `0x04` for
   `setAudioEnabled`; `setFrameInterval` moved to `0x05` (now `Sources/CaptureHelperWire.swift:89`).
3. **`.controlReleased` taking `0x0A`** — safe only because the TCP message-type space and the
   UDP control-byte space are deliberately disjoint (the comment at
   `Sources/ScreenShareProtocol.swift:69-70` documents exactly this near-miss).

Each was caught by hand during merge. Swift's compiler rejects duplicate raw values *within one
enum*, but that guard fires late (at integration, with a confusing diagnostic), says nothing
about the non-enum constants (RTP payload types, reserved SSRCs, capability bits, framing
sizes), and — worst — does nothing against silent *renumbering*: a rebased PR that shifts an
already-shipped byte breaks wire compatibility with deployed peers and compiles clean. There is
one existing pinning test (`LossRecoveryWireTests.testNewControlBytesAreDistinctAndInControlRange`,
`Tests/TailscreenTests/RTPPacketTests.swift:707-718`) but it covers only 3 of the 13 UDP control
bytes and nothing else.

Separately, the parsers that face hostile bytes (framed TCP parser, RTP depacketizers, UDP
control decoders) are tested against hand-written malformed cases but have never been fuzzed;
a handful of known loose ends (control-request spam, an RR accounting off-by-one, missing
NACK wraparound tests, a NaN-at-JSON-boundary assumption, a process-wide panic hotkey) remain
open; and CI never builds release config, never gates coverage on changed lines, and has no
long-run soak tier.

This plan bundles those into one small, de-risking iteration.

## Goals / Non-goals

**Goals**
- One test file that pins **every** wire constant, per channel, in a single table — exact
  values *and* intra-channel uniqueness — so a colliding or renumbered byte fails CI with a
  message that names both claimants.
- A deterministic, seeded, CI-able byte-level fuzz harness for the wire parsers: random bytes,
  truncations, bit-flips of valid frames, length-field mutations; asserting no crash, no hang,
  clean reject. Bounded runtime (~seconds).
- Close the five reviewed loose ends (sharer control-request preference + notification dedupe,
  RR fraction-lost accounting, NACK wraparound coverage, NaN/Infinity pinning, panic-hotkey
  lifecycle).
- Three CI additions: release-config build job, diff-coverage gate on changed lines, nightly
  seeded soak tier.

**Non-goals**
- **No wire-format changes.** No new bytes, no renumbering, no framing changes. (The one
  behavioral protocol tweak — RR accounting — changes the *values* a viewer reports, not the
  20-byte layout at `Sources/RTPPacket.swift:207-229`.)
- No libFuzzer / continuous-fuzzing infrastructure; this is XCTest-hosted deterministic
  fuzzing only.
- No flipping the existing informational CI jobs (`format`, `test-tsan`,
  `.github/workflows/build.yml:127,152`) to required — separate concern.
- No changes to the capture/picker helper process model or the TailscaleKit patches.

## Current state (with file:line references)

### The five wire channels and their actual values

**Channel A — TCP framed control channel** (`ScreenShareMessage.MessageType`,
`Sources/ScreenShareProtocol.swift:61-72`; framing `[type:1][len:4 BE][payload:N]`):

| Value | Case | Line |
|-------|------|------|
| 0x03 | `annotation` | :62 |
| 0x04 | `requestToShare` | :63 |
| 0x05 | `shareResponse` | :64 |
| 0x06 | `controlRequest` | :65 |
| 0x07 | `controlGranted` | :66 |
| 0x08 | `controlRevoked` | :67 |
| 0x09 | `inputEvent` | :68 |
| 0x0A | `controlReleased` | :71 |

Plus framing constants: `headerSize = 5` (:50), `maxPayloadLength = 1 << 20` (:59). Note 0x00-0x02
are unassigned (historical); the registry should record them as reserved so nobody "fills the gap"
without noticing old peers may treat them specially.

**Channel B — UDP control bytes** (`ScreenShareControlMessage`, `Sources/RTPPacket.swift:40-98`):

| Value | Case | Line |
|-------|------|------|
| 0x00 | `hello` | :41 |
| 0x01 | `keepalive` | :42 |
| 0x02 | `bye` | :43 |
| 0x03 | `pli` | :44 |
| 0x04 | `helloAck` | :45 |
| 0x05 | `serverBye` | :48 |
| 0x06 | `helloPending` | :52 |
| 0x07 | `codecUnsupported` | :58 |
| 0x08 | `helloDenied` | :62 |
| 0x09 | `profileUnsupported` | :70 |
| 0x0A | `nack` | :82 |
| 0x0B | `receiverReport` | :91 |
| 0x0C | `ping` | :98 |

Channel invariant: every value ≤ 0x7F so `looksLikeControl` (:111-114) keeps the space disjoint
from RTP's first-byte range 0x80-0xBF. Also in this channel's registry: `ScreenShareCaps` bits
(`nack = 1 << 0` :255, `receiverReport = 1 << 1` :257 — uniqueness of *bits*, not bytes).

**Channel C — capture-helper wire** (`Sources/CaptureHelperWire.swift`; same
`[type:1][len:4 BE][payload:N]` framing, but two independent type spaces on two pipes):

`OutType` (helper→main, :19-63): `accessUnit 0x01` (:21), `parameterSets 0x02` (:27),
`firstFrame 0x03` (:31), `previewJPEG 0x04` (:36), `userStopped 0x05` (:42), `heartbeat 0x06`
(:49), `audioAccessUnit 0x07` (:55), `logLine 0x10` (:59), `fatal 0xFF` (:62).

`InType` (main→helper, :66-93): `requestKeyframe 0x01` (:68), `setBitrate 0x02` (:70),
`contentFilter 0x03` (:78), `setAudioEnabled 0x04` (:84), `setFrameInterval 0x05` (:89),
`shutdown 0xFF` (:92).

**Channel D — picker-helper framing** (no type byte): a single `[length:4 BE][JSON bytes:N]`
payload, `length == 0` = user cancelled; writer `writeFramedPayload`
(`Sources/PickerHelperMain.swift:240-251`), reader `readFramed`
(`Sources/PickerHelperClient.swift:103-113`). Exit codes 0 (selection) / 1 (cancel) / ≥2 (error).
There are no named constants to pin — the registry pins the framing by round-trip (see Design).

**Channel E — RTP payload types and reserved SSRCs** (`Sources/RTPPacket.swift:283-300`):
`h264PayloadType = 96` (:283), `hevcPayloadType = 97` (:286), `aacPayloadType = 98` (voice, :289),
`systemAudioPayloadType = 99` (:296); `systemAudioSSRC = 1` (:300). Sharer voice owns SSRC 0
(the server packetizes voice with `ssrc: 0`, `Sources/TailscaleScreenShareServer.swift:3182,3186`)
and viewer SSRCs are allocated in `2...UInt32.max`
(`Sources/TailscaleScreenShareServer.swift:2032-2034` — the "Start at 2" floor is a bare literal
inside the allocation loop today).

### Parsers facing untrusted bytes (fuzz targets)

- `ScreenShareMessageParser` (`Sources/ScreenShareProtocol.swift:115-226`): incremental framed
  parser with the oversized-length poison guard (`isCorrupt`, :121,:139-143) and per-type JSON
  decodes (:178-225). Existing malformed coverage lives in `ScreenShareProtocolTests`
  (oversized-frame boundary, malformed-`.inputEvent`-decodes-to-nil).
- RTP depacketizers: `H264Depacketizer` (:653-873), `H265Depacketizer` (:1002-1202),
  `MultiCodecDepacketizer.ingest` (:1222-1232), `RTPHeader.decode` (:322-354, including the
  CSRC/extension skip arithmetic), `RTPReorderBuffer` (:565-645), `AVCCParser.nalUnits`
  (:361-377).
- UDP control decoders (`Sources/RTPPacket.swift`): `decode` (:104-107), `decodeHelloAck`
  (:128-131), `decodeHelloCaps` (:145-148), `decodeHelloAckCaps` (:165-170), `decodeNACK`
  (:190-204), `decodeReceiverReport` (:219-229), `decodePing` (:240-243).
- `AudioRTPDepacketizer.unpack` (`Sources/RTPAudio.swift:60-75`).
- Helper-wire payload parser: `decodeParameterSets`
  (`Sources/HelperScreenCapture.swift:284-311`) — currently `private`, and its `readBE32`
  (:313-319) indexes with **absolute** offsets (`data[offset]`), unlike the `startIndex`-relative
  style everywhere else. Safe today only because `HelperFrameReader.readExactly` always hands it
  a fresh zero-based `Data`; a fuzz harness feeding slices would trap. This is exactly the class
  of latent bug the harness should pin (see Design (b)).

Existing conventions to reuse: `SeededRNG` (SplitMix64, seedable —
`Tests/TailscreenTests/LossyChannel.swift:6-21`) and the deterministic-impairment philosophy of
`LossyChannel` / `RTPLossyChannelTests` (seeded, no wall clock, CI-able).

### Loose ends, verified against current main

1. **Control-request spam.** The server's only gate on `.controlRequest` is
   admitted-viewer IP (`Sources/TailscaleScreenShareServer.swift:1271-1282`); requests are
   keyed by TCP `connectionID` (`recordControlRequest`, :1102-1115), so every
   reconnect is a *new* UUID → `AppState.handleControlRequestsChanged`
   (`Sources/AppState.swift:2339-2346`) sees a new id and fires
   `ViewerJoinNotifier.postControlRequested` (`Sources/ViewerApproval.swift:93-107`)
   unconditionally. An admitted viewer can spam OS notifications by reconnect-and-request
   loops. There is no preference to turn control requests off entirely (grep: no
   `allowControlRequests` anywhere); the closest patterns are `requireViewerApproval`
   (`Sources/AppState.swift:129-131`) with its `ViewerApprovalDefaults` store and the
   Settings toggle at `Sources/SettingsView.swift:22-30`.
2. **RR fraction-lost off-by-one + duplicate inflation.** Client-side accounting in
   `recordRRPacket` (`Sources/TailscaleScreenShareClient.swift:913-926`) increments
   `rrReceivedSinceReport` unconditionally at :914 — *before* the baseline branch and before
   the duplicate check — and sets `rrExpectedBaseSeq = UInt32(seq)` (:917). The report math
   (:936-941) computes `expected = extHighest − rrExpectedBaseSeq`, which for a first interval
   of N in-order packets yields `expected = N−1` while `received = N`: the baseline packet is
   counted in `received` but not `expected`, so one genuine loss in the first interval is
   masked (`lost = max(0, expected − received)` clamps the −1). Duplicates (and served
   retransmits of already-counted seqs) also inflate `received` in every interval, masking
   further loss. This under-reports exactly when the congestion controller
   (`nextCongestionDecision`) most needs truth.
3. **NACKScheduler wraparound coverage.** `Sources/NACKScheduler.swift` uses wrap-safe `&-`/`&+`
   arithmetic throughout (`observe` :104,:121,:130-135; `evaluate` :172-182), but every case in
   `Tests/TailscreenTests/NACKSchedulerTests.swift` (13 tests) uses seqs in 0-300 — the
   `highestSeq` wrap at 65535→0 is never crossed. Additionally `packFCI` (:243-261) and
   `fciCappedSeqs` (:212-231) use plain `sorted()`, which is **not** wrap-aware: a gap set
   spanning the wrap (e.g. {65534, 65535, 0, 1}) sorts as [0, 1, 65534, 65535] and splits into
   two FCI groups instead of one. That's an efficiency wart, not a correctness bug (every seq is
   still covered; `decodeNACK`/server lookup are per-seq) — but it's exactly the kind of
   behavior that should be pinned by a test so a future "fix" doesn't silently drop coverage.
   Precedent: `RetransmitBufferTests.testSeqWraparoundLookup`
   (`Tests/TailscreenTests/RetransmitBufferTests.swift:33`).
4. **NaN/Infinity at the JSON boundary.** `InputEvent` coordinates are plain `Double`s
   (`Sources/RemoteControl.swift:14-24`). The coordinate clamp `min(max(nx, 0), 1)` in
   `RemoteControlMapping.globalPoint` (`Sources/RemoteControlMapping.swift:18-19`) **propagates
   NaN** (Swift's `min`/`max` return the NaN operand when comparisons are false), so a NaN
   coordinate reaching the injector would produce a NaN `CGPoint`. The only thing preventing
   that today is `decodeInputEvent`'s stock `JSONDecoder`
   (`Sources/ScreenShareProtocol.swift:220-225`), whose default
   `nonConformingFloatDecodingStrategy = .throw` rejects `NaN`/`Infinity` tokens and
   out-of-range literals like `1e999`. That's a load-bearing default with zero tests pinning
   it. (The scroll path already defends itself: the `isFinite` guard inside
   `MacPointerMapping.ScrollLineAccumulator.step` — formerly `clampToInt32` in the
   injector. Mouse coordinates have no such guard.)
5. **Panic hotkey registered process-wide regardless of role.** `revokeControlHotkey` (⌃⌥.) is
   created unconditionally in `AppState.init` (`Sources/AppState.swift:523-529`, beside the mic
   hotkey :511-518) and lives for the process lifetime; `GlobalHotkey` registers in `init` and
   unregisters only in `deinit` (`Sources/GlobalHotkey.swift:50-58`). So every Tailscreen
   instance — including pure viewers and idle menubar sessions — swallows ⌃⌥. system-wide even
   though the handler no-ops without a grant. The natural lifecycle hook already exists:
   `onControlGrantChanged` is observed at `Sources/AppState.swift:884`.

### CI today

`.github/workflows/build.yml`: jobs `build` (make build + `swift test --enable-code-coverage`
+ an informational `llvm-cov report` summary + profdata artifact), `lint`, `format`
(continue-on-error, :127), `test-tsan` (continue-on-error, :152). Debug configuration only —
release config is exercised only by the Release workflow, which fires on published releases.
No coverage gate of any kind; no scheduled runs.

## Design

### (a) Wire-byte registry test — `Tests/TailscreenTests/WireByteRegistryTests.swift`

One file, one table per channel, three assertions per channel:

```swift
/// One row: (constant name as it appears in source, pinned wire value).
typealias WireRow = (name: String, value: UInt8)

private func assertRegistry<E: CaseIterable & RawRepresentable>(
    channel: String, enum _: E.Type, pinned: [WireRow]
) where E.RawValue == UInt8 {
    // 1. Exactness: every pinned row matches the live enum.
    // 2. Exhaustiveness: every live case has a pinned row (a new case
    //    added without updating the registry fails here, by name).
    // 3. Uniqueness: no two rows claim the same byte — the failure message
    //    names BOTH claimants and says "pick the next free value".
}
```

- **Channel A (TCP):** pinned table for the 8 `MessageType` cases above, plus
  `headerSize == 5` and `maxPayloadLength == 1 << 20`, plus a row-comment reserving 0x00-0x02.
- **Channel B (UDP):** pinned table for all 13 control bytes, plus the channel invariants —
  every byte ≤ 0x7F, `looksLikeControl(encode(kind))` true for each, and `looksLikeControl`
  false for 0x80/0xBF/0xB3 (RTP space). `ScreenShareCaps`: pin `nack == 1<<0`,
  `receiverReport == 1<<1`, and bit-disjointness (`rawValue & other == 0` pairwise) so a new
  cap can't shadow an old one.
- **Channel C (helper wire):** two pinned tables (`OutType`, `InType`) — the spaces are
  independent (both use 0x01-0x05 and 0xFF legitimately), which the test documents by
  construction: uniqueness is asserted *within* each table, never across the two.
- **Channel D (picker framing):** no constants to table. Pin behaviorally: a round-trip
  through a `Pipe` — write a payload with the production writer path, read with the production
  reader path, assert byte-identity; write a zero-length frame, assert the reader returns nil
  (cancel semantics); assert the header is exactly 4 bytes big-endian by hand-decoding.
  Requires making `writeFramedPayload` reachable (see seams below).
- **Channel E (PTs + SSRCs):** pin 96/97/98/99, assert all four distinct and within the
  dynamic-PT range 96...127; pin `systemAudioSSRC == 1`, the voice SSRC 0, and the viewer
  floor 2 with the ordering invariant `voice < systemAudio < firstViewerSSRC`.

**Cross-channel note, asserted as documentation:** the test includes a deliberately-passing
assertion that TCP 0x0A (`controlReleased`) and UDP 0x0A (`nack`) coexist — encoding in a test
that the two spaces are disjoint *on purpose*, so the next person who notices the "collision"
finds the explanation in a test name instead of re-litigating it.

**Small source changes required (all zero-behavior):**
- Add `CaseIterable` to `ScreenShareMessage.MessageType`, `ScreenShareControlMessage`,
  `CaptureHelperWire.OutType`, `CaptureHelperWire.InType` (compiler-synthesized; this is what
  makes the exhaustiveness leg work).
- Extract the viewer-SSRC floor as `static let firstViewerSSRC: UInt32 = 2` on `RTPHeader`
  (next to `systemAudioSSRC`, `Sources/RTPPacket.swift:300`) and use it in the allocation loop
  (`Sources/TailscaleScreenShareServer.swift:2034`) — mirrors how `TransportTuning` centralized
  its literals (pinned by `QualitySettingsTests`).
- Give the picker framing writer a test seam: hoist `writeFramedPayload`
  (`Sources/PickerHelperMain.swift:240-251`) to `internal` (e.g. a small
  `enum PickerHelperFraming`) used by both the helper and the test. The reader side
  (`PickerHelperClient.readFramed`) gets the same treatment or is exercised through a `Pipe`.

Once landed, fold `LossRecoveryWireTests.testNewControlBytesAreDistinctAndInControlRange`'s
three pinned bytes into the registry and shrink that test to the round-trip parts (avoid two
sources of truth).

### (b) Seeded parser fuzz harness — `Tests/TailscreenTests/ParserFuzzTests.swift`

Deterministic XCTest, reusing `SeededRNG` (`Tests/TailscreenTests/LossyChannel.swift:6-21`).
No `Date()`, no unseeded `random`, no sleeps. Fixed iteration budgets (~2,000 per strategy per
target) keep the whole suite in low single-digit seconds; every case logs its seed in the
failure message so a red run reproduces exactly.

Four strategies, applied per target:

1. **Random bytes.** Lengths drawn 0...64 for UDP control datagrams, 0...1500 for RTP packets,
   0...4 KiB for framed streams. Feed and assert clean reject (nil / `[]` / no message) or a
   sane parse — never a crash.
2. **Truncations.** Take valid encodes (from the *production* encoders: `encodeNACK`,
   `encodeReceiverReport`, `encodePing`, `encodeHelloAck(ssrc:caps:)`,
   `ScreenShareMessage.encode()`, `H264Packetizer`/`H265Packetizer` output,
   `AudioRTPPacketizer.packetize`) and feed every strict prefix.
3. **Bit-flips.** Flip 1-3 seeded-random bits in valid frames/packets; assert no crash and —
   for the framed TCP parser — that a flip inside one frame's payload never desyncs the
   *following* intact frame (header-driven framing must resync).
4. **Length-field mutations.** For the two framed channels (TCP control, helper wire): patch
   the 4-byte BE length to 0, len±1, `maxPayloadLength`, `maxPayloadLength + 1`, `0xFFFFFFFF`.
   For the TCP parser assert the poison contract: `isCorrupt` latches, `next()` returns nil
   forever, subsequent `append` doesn't grow memory (feed 10 MB post-poison and rely on the
   existing `removeAll` behavior at `Sources/ScreenShareProtocol.swift:126-127,141`).

Targets and their invariants:

| Target | Entry point | Invariant |
|--------|-------------|-----------|
| `ScreenShareMessageParser` | `append`/`next` with seeded re-chunking (split the byte stream at random boundaries — exercises the incremental path) | no crash; unknown types skipped; poison latches; intact frames around a corrupt payload still parse |
| `MultiCodecDepacketizer` (drives both H.264/HEVC paths + `RTPReorderBuffer`) | `ingest` + `drainReady` | no crash; emitted AUs walk cleanly through `AVCCParser.nalUnits` (terminates, consumes ≤ AU length); `readyQueue` never grows unboundedly across a 10k-packet storm |
| `RTPHeader.decode` | direct | no crash on any input incl. lying CSRC counts / extension lengths (:337-343) |
| UDP control decoders | `decode*` family | nil/`[]` on malformed; exact round-trip on unmutated |
| `AudioRTPDepacketizer.unpack` | direct | nil on malformed; PT gate holds (96/97 rejected) |
| `decodeParameterSets` | via new internal seam | nil on malformed; **fed both zero-based `Data` and slices** (`dropFirst` re-based) — this pins the absolute-offset `readBE32` hazard at `Sources/HelperScreenCapture.swift:313-319`; fix the indexing to `startIndex`-relative as part of this item |

"No hang" is enforced structurally: every parser here is synchronous and loop-bounded by input
length, and the harness feeds bounded inputs — a wedge would surface as the suite blowing its
CI timeout, which is the correct failure mode for a hang.

Convention note: this file joins the CI-able pure suites; CLAUDE.md's test list gets a line for
it in the same commit (the "add it to this list" rule).

### (c) Loose ends

**(c1) "Allow control requests" toggle + per-IP notification dedupe.**
- New `RemoteControlDefaults` (mirrors `SystemAudioDefaults`, `Sources/SystemAudioDefaults.swift`)
  persisting `allowControlRequests`, default **on**. `AppState` publishes it (pattern:
  `requireViewerApproval`, `Sources/AppState.swift:129-131`); Settings gets a "Remote control"
  section with `Toggle(L("Allow control requests"), …)` + caption (pattern:
  `Sources/SettingsView.swift:22-30`; strings through `L(_:)` + catalog entries in `en.lproj`
  *and* `sv.lproj`, or `LocalizationCatalogTests` fails).
- Server side: a `controlRequestsAllowed` flag (set via a setter from `AppState`, re-sent on
  share start like the audio latch). The gate lives in `listener.onControlRequest`
  (`Sources/TailscaleScreenShareServer.swift:1271-1282`): when off, drop the request and reply
  `.controlRevoked(reason: "control requests disabled")` on the same connection so the viewer's
  UI leaves the `requested` state immediately instead of waiting forever.
- Notification dedupe by **IP, not connectionID**: extract a pure decision
  `AppState.controlRequestNotificationDecision(newRequests:previouslyNotifiedIPs:) -> (notify: [ControlRequestInfo], notifiedIPs: Set<String>)`
  — one OS notification per viewer IP per share (the pending row in the popover still shows
  every live request; only the *notification* is deduped). The notified-IP set clears on
  `stopSharing` alongside `controlRequests = []` (`Sources/AppState.swift:1018`). Keying by IP
  defeats the reconnect-new-UUID spam; the source IP is the same non-spoofable anchor the
  admission gate already trusts.

**(c2) RR accounting fix.** Extract the client's RR bookkeeping (currently five loose vars +
two funcs, `Sources/TailscaleScreenShareClient.swift:913-957`) into a small pure
`struct RRAccounting` (observe(seq:) / makeReport() — the extract-the-decision pattern), fixing
both defects in the move:
- **Baseline:** count the first packet in *both* legs — either report
  `expected = extHighest − base + 1` for the interval that establishes the baseline, or store
  the baseline as `extFirst − 1` in the 64-bit extended-seq space (avoids the `UInt32` underflow
  when the first seq is 0). Result: N packets, no loss → `expected == received == N`.
- **Duplicates:** track received seqs in a small sliding window (e.g. a 1024-bit bitset over
  the extended-seq space — matching the reorder window's scale) and only count first arrivals.
  A served NACK retransmit *is* a first arrival of that seq and still counts as received —
  which is precisely RFC 3550's intent and what lets `nextCongestionDecision` see
  NACK-recovered loss as recovered.
- The wire layout (`Sources/RTPPacket.swift:207-229`) is untouched; only reported values become
  truthful. Server-side consumers (`handleReceiverReport`,
  `Sources/TailscaleScreenShareServer.swift:1549-1551` dispatch) need no change.

**(c3) NACKScheduler wraparound tests.** Extend `NACKSchedulerTests` with a wrap block (seqs
65530+): gap opened across the boundary (observe 65534 then 2 → gaps {65535, 0, 1} all tracked
and NACKed); straggler across the wrap fills its gap (and feeds the RTT sample, :109-111);
`>maxGaps` discontinuity computed across the wrap still yields `.sendPLI` (:121-125); `packFCI`
and `fciCappedSeqs` given {65534, 65535, 0, 1} — **pin current behavior**: two FCI groups (the
sort splits at the wrap) but every seq covered. Mirror the same wrap cases through
`ScreenShareControlMessage.encodeNACK`/`decodeNACK` round-trip. No production change expected;
if the wrap tests surface a real defect, fixing it is in scope.

**(c4) NaN/Infinity pinning.** Three layers, all CI-able:
- `ScreenShareProtocolTests`: hand-built `.inputEvent` frames whose JSON payloads carry
  `NaN`, `Infinity`, `-Infinity` tokens and the overflow literal `1e999` in `x`/`y`/deltas —
  assert `next()` yields nil for each (pinning the `.throw` default at
  `Sources/ScreenShareProtocol.swift:220-225`), and that a valid frame after the rejected one
  still parses.
- Defense-in-depth: make `RemoteControlMapping.globalPoint`
  (`Sources/RemoteControlMapping.swift:18-19`) NaN-safe — non-finite input maps as 0 (the same
  policy as `MacPointerMapping.ScrollLineAccumulator`) — so the clamp no
  longer depends on a decoder default two layers away. Pin in `RemoteControlMappingTests`.
- A comment on `decodeInputEvent` naming the invariant, so nobody "improves" the decoder with
  `.convertFromString` without tripping over the tests.

**(c5) Panic-hotkey lifecycle.** Move `revokeControlHotkey` out of `AppState.init`
(`Sources/AppState.swift:523-529`): create it when a grant appears and destroy it when the
grant clears, inside the existing `onControlGrantChanged` handler (:884) — `grant != nil` →
instantiate if nil; `grant == nil` → set to nil (deinit unregisters,
`Sources/GlobalHotkey.swift:56-58`). Revoke/stop/disconnect paths already funnel through the
server's grant-change notification, so no extra unregister sites are needed; `stopSharing`'s
grant teardown clears it for free. The mic hotkey (⌃⌥M) keeps its process-lifetime
registration — it's useful in both roles. `GlobalHotkeyTests.handlerShouldFire` is unaffected
(the id-dispatch filter doesn't care when registration happens); add a lightweight state test
if a pure seam falls out naturally, otherwise this is covered by the local E2E remote-control
suite.

### (d) CI additions (`.github/workflows/build.yml` + one new workflow)

1. **Release-config build job.** New `build-release` job beside `build` (:27): checkout with
   `submodules: recursive`, `actions/setup-go@v5` (same cache-dependency-path), `make tailscale`,
   then `PKG_CONFIG_PATH="$PWD/Packages/TailscaleKit" swift build -c release`. No tests, no
   artifact — the point is that `-O` + cross-module optimization + stripped `assert()`s compile
   clean on every PR instead of first breaking on a published release. Required (not
   continue-on-error): a release-config compile break is always real.
2. **Diff-coverage gate on changed lines.** Extend the `build` job after the existing
   "Coverage summary" step (which already produces `default.profdata`): export lcov via
   `xcrun llvm-cov export -format=lcov` (same binary/profdata discovery the summary step
   already does), then a new `scripts/diff-coverage.sh` that (a) `git diff -U0
   origin/main...HEAD -- 'Sources/*.swift'` to collect changed line ranges (checkout needs
   `fetch-depth: 0`), (b) joins them against the lcov `DA:` records, (c) fails if <70 % of
   changed executable lines are covered, printing the uncovered file:line list. Start
   `continue-on-error: true` with the same explicit flip-to-required TODO convention the
   `format` job uses (:117-127); flip once observed stable. Doc-only PRs already skip the
   workflow (paths-ignore, :8-19), so the gate never runs against an empty diff.
3. **Nightly soak tier.** New `.github/workflows/soak.yml`: `schedule: cron '17 3 * * *'` +
   `workflow_dispatch`, macos-latest, submodules + Go setup, `make tailscale`, then
   `TAILSCREEN_SOAK=1 swift test --filter SoakTests`. `Tests/TailscreenTests/SoakTests.swift`
   self-skips (`XCTSkip`) unless `TAILSCREEN_SOAK=1`, so `make test` and PR CI never pay for
   it. Content: the existing `RTPLossyChannelTests` pipeline (packetize → `LossyChannel` →
   NACK/depacketize → assert recovery invariants) swept over a seeded matrix — ~64 seeds ×
   {loss 1/3/10/30 %} × {reorder window 0/4/16} × {dup 0/5 %}, plus a long-run
   `ParserFuzzTests` pass at ~50× the PR iteration budget. Every case derives its seed from
   the matrix coordinates (not the clock), so a red nightly names the exact reproducing
   configuration in the failure message. Budget: tens of minutes, once a day, no concurrency
   group needed.

## Implementation steps (ordered checklist)

1. [x] Source seams for the registry: `CaseIterable` on the four wire enums;
   `RTPHeader.firstViewerSSRC = 2` (+ use at `TailscaleScreenShareServer.swift:2034`);
   hoist picker framing writer/reader to an internal `PickerHelperFraming`.
2. [x] `Tests/TailscreenTests/WireByteRegistryTests.swift` — five channel tables, exactness +
   exhaustiveness + uniqueness helpers, channel invariants (≤0x7F, PT range, SSRC ordering,
   picker round-trip), the cross-channel disjointness documentation assertion. Fold the three
   pinned bytes out of `LossRecoveryWireTests.testNewControlBytesAreDistinctAndInControlRange`.
3. [x] Fix `decodeParameterSets` indexing to `startIndex`-relative and make it `internal`
   (`HelperScreenCapture.swift:284-319`); `Tests/TailscreenTests/ParserFuzzTests.swift` with
   the four strategies × seven targets, seeded, budgeted.
4. [x] `RRAccounting` extraction + baseline/duplicate fixes in
   `TailscaleScreenShareClient.swift:913-957`; new `RRAccountingTests` (baseline interval,
   duplicate storm, wrap across 65535 via extended seq, retransmit-counts-once).
5. [x] NACK wrap tests in `NACKSchedulerTests` (+ `encodeNACK`/`decodeNACK` wrap round-trip in
   `RTPPacketTests`); fix anything they surface.
6. [x] NaN/Infinity: parser-reject cases in `ScreenShareProtocolTests`; NaN-safe
   `globalPoint` + `RemoteControlMappingTests` cases; invariant comment on `decodeInputEvent`.
7. [x] `RemoteControlDefaults` + `AppState.allowControlRequests` + Settings section + server
   gate + `.controlRevoked` decline reply; pure notification-dedupe decision + tests
   (`RemoteControlPolicyTests` or a small new suite); catalog entries for `en`/`sv`.
8. [x] Panic-hotkey lifecycle move into the `onControlGrantChanged` handler.
9. [x] CI: `build-release` job; `scripts/diff-coverage.sh` + gate step (warn-first);
   `.github/workflows/soak.yml` + `SoakTests.swift`.
10. [x] CLAUDE.md bookkeeping in the same commits: new suites added to the pure-decision test
    list; the two new env affordances (`TAILSCREEN_SOAK`) in the env-var table; CI section
    gains the two new jobs/workflow.

Steps 1-2, 3, 4, 5, 6, 7, 8, 9 are independently landable PRs in roughly that order of value;
the registry (1-2) goes first because every later step adds wire-adjacent tests it protects.

## Files to change / add

- `Tests/TailscreenTests/WireByteRegistryTests.swift` — new (the centerpiece).
- `Tests/TailscreenTests/ParserFuzzTests.swift` — new.
- `Tests/TailscreenTests/SoakTests.swift` — new (env-gated).
- `Sources/ScreenShareProtocol.swift`, `Sources/RTPPacket.swift`,
  `Sources/CaptureHelperWire.swift` — `CaseIterable`, `firstViewerSSRC`, comments only.
- `Sources/PickerHelperMain.swift` / `Sources/PickerHelperClient.swift` — framing seam hoist.
- `Sources/HelperScreenCapture.swift` — `decodeParameterSets` indexing fix + `internal`.
- `Sources/TailscaleScreenShareClient.swift` — `RRAccounting` extraction/fix.
- `Sources/RemoteControlMapping.swift` — NaN-safe clamp.
- `Sources/TailscaleScreenShareServer.swift` — control-requests-allowed gate; `firstViewerSSRC`
  use.
- `Sources/AppState.swift` — toggle plumbing, notification dedupe, hotkey lifecycle.
- `Sources/SettingsView.swift`, `Sources/Resources/{en,sv}.lproj/Localizable.strings` — toggle UI.
- New `Sources/RemoteControlDefaults.swift` (or fold into an existing defaults file).
- `Tests/TailscreenTests/{NACKSchedulerTests,RTPPacketTests,ScreenShareProtocolTests,RemoteControlMappingTests,RemoteControlPolicyTests}.swift`
  — extended.
- `.github/workflows/build.yml`, `.github/workflows/soak.yml`, `scripts/diff-coverage.sh` — CI.
- `CLAUDE.md` — test-list + env-table + CI bookkeeping.

## Testing strategy

Everything in this plan except (c5) is CI-able by construction — that's the point of it.

- **Registry:** the test *is* the deliverable. Meta-check during development: temporarily
  renumber one byte locally and confirm the failure message names the constant and both
  claimants readably.
- **Fuzz:** deterministic seeds; PR budget ~seconds (measure with `swift test --filter
  ParserFuzzTests` and trim iteration counts to keep the suite <5 s on the CI runner);
  nightly runs the same code at ~50× budget.
- **RR fix:** `RRAccountingTests` pure cases (above); regression — `CongestionDecisionTests`
  pass unchanged (they test `nextCongestionDecision` directly and don't depend on the client's
  accounting); the live path is observable locally via `scripts/net-impair.sh up --loss 3` +
  the stats overlay (fraction-lost should now be nonzero in the first second of a lossy
  session).
- **Control-request toggle + dedupe:** pure decision tests for the dedupe; the server gate
  gets a case in the local-only `ScreenShareRemoteControlTests` (request with toggle off →
  viewer sees `.controlRevoked`, `onControlRequestsChanged` never fires) — same suite that
  already covers the grant flow, rides local headscale, skips on CI.
- **Hotkey lifecycle:** covered by `ScreenShareRemoteControlTests` extension (grant → hotkey
  object non-nil; revoke → nil) if a seam is exposed; otherwise manual (⌃⌥. types a period in
  TextEdit while idle — today it doesn't).
- **CI changes:** validated on the PR that introduces them (the release job and the
  warn-only diff gate run on their own PR); soak validated once via `workflow_dispatch`.

## Risks & pitfalls

- **The registry must not fossilize accidents.** Its failure message must distinguish "you
  collided — pick the next free value" from "you renumbered — if intentional, update the
  registry row *and* confirm no shipped peer depends on the old value (see the PROFILE_NO and
  HELLO_DENY back-compat notes at `RTPPacket.swift:27-38`)". Bake both sentences into the
  assertion text.
- **Uniqueness scope discipline.** OutType/InType overlap legitimately (both own 0x01-0x05,
  0xFF), and TCP/UDP share 0x03-0x0A by design. Uniqueness is asserted strictly per-table;
  asserting it across tables would institutionalize a false invariant and block legitimate
  values. The cross-channel documentation assertion exists precisely to head off a
  well-meaning "fix".
- **Fuzz flakiness = determinism leaks.** No `Date()`, no unseeded RNG, no timers; the only
  acceptable nondeterminism is XCTest ordering, which the harness must not depend on. Reuse
  `SeededRNG`, print seeds in failures. (This is why the harness does *not* try to fuzz the
  `FileHandle`-based helper readers — pipes add scheduling nondeterminism for little parser
  coverage; the payload decoders are fuzzed directly.)
- **Data-slice indexing.** Several parsers index `startIndex`-relative (correct for slices),
  `decodeParameterSets` doesn't (`HelperScreenCapture.swift:313-319`). The fuzz harness feeds
  re-based slices everywhere specifically to catch this class; fix that one *before* enabling
  its slice cases or the harness's first run is red.
- **RR semantics change is protocol-adjacent.** Old servers receive slightly different (more
  truthful) `fracLostQ8` values from fixed viewers — within the field's defined meaning, no
  layout change, no compat risk. Don't "fix" it server-side too (double-correcting).
- **Control-request decline reply reuses `.controlRevoked`** (`0x08` TCP) rather than minting
  a new message type — deliberate: old viewers already handle it (their UI clears), and the
  registry stays byte-stable. Resist the temptation to add a `controlDenied` byte in this
  iteration.
- **Hotkey churn:** Carbon register/unregister per grant is cheap, but the handler dispatch
  filter (`GlobalHotkey.handlerShouldFire`) exists because ids collide when two hotkeys are
  live — keep the revoke hotkey's `id: 2` (`AppState.swift:526`) so a grant during a share
  with the mic hotkey registered keeps both working (that's the exact regression
  `GlobalHotkeyTests` pins).
- **Diff-coverage gate false failures** on pure-decl changes (imports, comments) — lcov `DA:`
  records only cover executable lines, which handles most of it, but keep the gate warn-only
  until it's been observed across a few real PRs (the `format` job's proven pattern).
- **Localization:** two new user-facing strings minimum (toggle + caption) must land in both
  `en.lproj` and `sv.lproj` or `LocalizationCatalogTests` fails CI.

## Estimated scope

**M overall, but highly parallelizable** — eight independently landable pieces.
Registry: ~30 LOC source seams + ~200 LOC test. Fuzz harness: ~1 line source fix + ~300 LOC
test. RR: ~80 LOC source (mostly moved) + ~100 LOC test. NACK wrap: ~80 LOC test. NaN: ~15 LOC
source + ~60 LOC test. Control-request toggle/dedupe: ~120 LOC source + ~80 LOC test + catalog.
Hotkey: ~15 LOC moved. CI: ~90 lines YAML + ~50-line script + ~80 LOC SoakTests. No wire-format
changes anywhere.
