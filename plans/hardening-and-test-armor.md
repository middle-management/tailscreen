# Hardening & test armor: wire-byte registry, parser fuzzing, and closing known gaps

> **Status: shipped in full** (verified against the tree 2026-08-06). All ten
> steps landed. Kept for the rationale behind decisions someone might
> otherwise re-propose or "fix."

## Problem & motivation

Three near-collisions of protocol byte values happened across concurrent PRs
(e.g. PROFILE_NO vs HELLO_DENY both briefly claiming `0x08`; `setFrameInterval`
vs `setAudioEnabled` both claiming helper-wire `0x04`). Swift's compiler only
catches duplicate raw values *within one enum*, late, and does nothing against
silent renumbering of an already-shipped byte (which breaks wire compat with
deployed peers and compiles clean). Separately: the parsers facing untrusted
bytes had never been fuzzed, and five loose ends were open (control-request
notification spam, an RR accounting off-by-one, missing NACK wraparound tests,
a NaN-at-JSON-boundary assumption resting on an undocumented default, a
process-wide panic hotkey). CI also never built release config, never gated
coverage, and had no soak tier.

## Key decisions & why

- **One `WireByteRegistryTests` file, one table per channel** (TCP framed
  control, UDP control bytes, helper-wire `OutType`/`InType`, picker framing,
  RTP payload types/SSRCs), each asserting exactness + exhaustiveness (every
  live enum case has a pinned row — new cases fail loudly) + uniqueness
  (collision failure names both claimants). `CaseIterable` added to the four
  wire enums specifically to make exhaustiveness checkable.
- **Uniqueness is scoped per-channel, not global, on purpose.** TCP and UDP
  legitimately share byte values (disjoint spaces), and helper-wire
  `OutType`/`InType` are independent spaces that both reuse `0x01-0x05`/`0xFF`.
  A deliberately-passing cross-channel assertion documents this so nobody
  "fixes" it later. Rejected: asserting uniqueness across all channels — would
  institutionalize a false invariant.
- **Deterministic, seeded fuzzing (XCTest-hosted), not libFuzzer/continuous
  fuzzing.** Keeps it CI-able and bounded (~seconds per PR run, ~50x budget
  nightly); every failure logs its seed for exact reproduction. Four
  strategies (random bytes, truncations of valid encodes, bit-flips, length-
  field mutations) applied across the TCP parser, RTP depacketizers, UDP
  control decoders, audio depacketizer, and the helper's `decodeParameterSets`.
  Fuzzing `decodeParameterSets` with re-based slices caught a real hazard:
  absolute-offset indexing (`data[offset]`) that only worked because its one
  caller always handed zero-based `Data` — fixed to `startIndex`-relative.
- **RR accounting fix keeps the wire layout untouched** — only the *values* a
  viewer reports become truthful (baseline off-by-one masked one loss per
  interval; duplicates/retransmits inflated `received`). Extracted to a pure
  `RRAccounting` struct (extract-the-decision pattern). A served NACK
  retransmit still counts as a first arrival — intentional, matches RFC 3550
  and lets `nextCongestionDecision` see NACK-recovered loss as recovered.
- **Control-request notification dedupe keys on source IP, not TCP
  connectionID** — a reconnect gets a new connection UUID (spammable) but the
  same IP, and IP is the same non-spoofable anchor the admission gate already
  trusts. The decline reply reuses the existing `.controlRevoked` byte rather
  than minting a new wire message — old viewers already handle it and the
  registry stays byte-stable.
- **Panic hotkey (⌃⌥.) now lifecycle-scoped to an active control grant**
  (created/destroyed in the existing `onControlGrantChanged` handler) instead
  of process-wide — a pure viewer or idle menubar session no longer swallows
  the shortcut system-wide for a handler that no-ops anyway. The mic hotkey
  keeps process-lifetime registration since it's useful in both roles.
- **NaN/Infinity defense in depth, not reliance on one default.** `JSONDecoder`'s
  `.throw` on non-conforming floats already rejected NaN/Infinity/`1e999`, but
  nothing pinned it. Added: parser-reject tests pinning that default, *and* a
  NaN-safe `RemoteControlMapping.globalPoint` (non-finite → 0, matching the
  scroll path's existing policy) so the clamp doesn't depend on a decoder
  default two layers away.
- **CI: release-config build required, coverage gate warn-first.** A release
  build (`-O`, stripped asserts) now compiles on every PR instead of first
  breaking on a published release. The diff-coverage gate (70% of changed
  lines) starts `continue-on-error` and flips to required once observed
  stable — same pattern already used for the `format` job. A new nightly
  `soak.yml` sweeps the lossy-channel/NACK pipeline and a long fuzz pass over
  a seeded matrix, self-skipped in normal `swift test` via `TAILSCREEN_SOAK`.

## Notes on scope decisions

- No wire-format changes anywhere in this plan — new bytes/framing were
  explicitly out of scope; only test coverage and internal accounting moved.
- Fuzzing deliberately skips the `FileHandle`-based helper readers (pipes add
  scheduling nondeterminism for little parser coverage); the payload decoders
  are fuzzed directly instead.
- NACK wraparound: `packFCI`/`fciCappedSeqs` use plain (non-wrap-aware)
  `sorted()`, so a gap set spanning the 65535→0 boundary splits into two FCI
  groups instead of one. Confirmed as an efficiency wart, not a correctness
  bug (every seq is still covered per-seq at lookup) — pinned by a test
  rather than "fixed," so a future change doesn't silently drop coverage
  without someone noticing the tradeoff.
- Diff-coverage gate counts only lcov `DA:` (executable) lines, so it doesn't
  false-fail on import/comment-only diffs.

## Where it lives

- Registry: `WireByteRegistryTests.swift` (`CaseIterable` wire enums,
  `RTPHeader.firstViewerSSRC`, `PickerHelperFraming` seam).
- Fuzzing: `ParserFuzzTests.swift`, `decodeParameterSets` internal seam.
- RR fix: `RRAccounting` (TailscreenProtocol) + `RRAccountingTests`.
- NaN safety: `RemoteControlMapping.globalPoint`.
- Control-request toggle: `RemoteControlDefaults`, `AppState.allowControlRequests`,
  Settings toggle.
- Hotkey lifecycle: `AppState`'s `onControlGrantChanged` handler.
- CI: `build-release` job, `scripts/diff-coverage.sh`, `.github/workflows/soak.yml`,
  `SoakTests`.
- Test bookkeeping conventions are now owned by the `test-catalog` skill,
  not this file.
- Full wire byte tables/values: `.claude/rules/protocol.md`, `docs/spec.md`.
