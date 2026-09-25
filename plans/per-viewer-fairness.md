# Per-viewer isolation: one slow viewer must not degrade the session for everyone

> **Status: shipped**, with several adaptations from the original design (see
> Deviations). Current code: `TailscaleScreenShareServer.swift`
> (`audioSendTails`, `lossAttribution`, `fairnessDecision`, `shouldSendFrame`),
> `CongestionControl.swift`, `ViewerHealth` in the roster, tests in
> `PerViewerFairnessDecisionTests` / `ViewerLifecycleDecisionTests`.

## Problem & motivation

Encode-once-fan-out (per-viewer RTP header rewrite) creates three "worst
viewer wins" couplings unless broken explicitly: (1) a single shared audio
send chain meant one blocked viewer delayed audio to everyone; (2) adaptive
bitrate fed the *max* per-viewer PLI count into the global rate, so one bad
link dragged every healthy viewer down; (3) nothing surfaced which viewer was
the problem. Video transport already had per-viewer send chains — the
pattern this plan extended to audio and to loss attribution.

## Key decisions & why

- **Per-viewer audio send chains, mirroring the existing video chains** —
  same bounded-queue/drop-newest pattern, not a new mechanism. Audio is
  loss-tolerant by design (gap concealment already exists), so drop-newest
  needs no queue surgery.
- **Audio chain pruning happens at viewer-removal points, not by rebuilding
  per send (deviation from the original plan).** Video's fan-out has one
  producer addressing every viewer each broadcast, so a rebuild-from-plan-set
  prunes safely. Audio has multiple producers (mic-out addresses all
  viewers; each viewer's relay addresses all-but-itself) hitting different
  recipient subsets — a rebuild on one path could drop another producer's
  live chain and break its ordering. So chains are mutated in place and
  pruned at `removeViewer`/`expelViewer`/idle-sweep/`stop()` instead.
- **Loss attribution distinguishes "one bad viewer" from "everyone
  suffering"** (`lossAttribution`): exactly one viewer over the PLI
  threshold with every other viewer clean, and at least 2 viewers total (a
  lone viewer has no "everyone else" to compare against, so it stays
  `.widespread` — unchanged behavior).
- **Isolated bad viewers are throttled to keyframe-only, not dropped or
  degrade-all.** Rejected alternatives: degrade-all (the original problem);
  drop-worst (ejecting on possibly-transient loss is user-hostile as an
  automatic action). Keyframe-only is the only per-viewer frame-skipping
  that stays decodable — P-frames form a reference chain, so skipping
  arbitrary non-keyframes corrupts everything until the next IDR, while
  keyframes are self-contained.
- **Throttled viewers are excluded from the global bitrate input in *every*
  verdict, not just `.isolated`** (deviation, broader than planned) — a
  viewer already in keyframe-only mode has expected PLIs from its own
  intentional frame-skipping, which must never drive a global cut even
  during a `.widespread` window caused by someone else.
- **No sequence-number reservation for skipped frames sent to a throttled
  viewer** — reserving them would make the throttled viewer perceive ~100%
  loss, PLI at max rate, and re-trigger its own throttle forever. This is
  the opposite of the existing backlog-drop behavior (which does reserve
  sequences) and the two must not be unified. Implemented as pure
  `shouldSendFrame(isKeyframe:throttledUntilNs:nowNs:)` so the
  sequence-contiguity invariant is CI-testable.
- **Simulcast/per-viewer re-encode explicitly deferred** — the helper wire
  supports exactly one encode session (no session/layer id anywhere on the
  wire), so simulcast needs multi-encoder support, layer-tagged AU frames,
  per-viewer layer selection, and ~2x helper CPU. Keyframe-only throttling
  gets most of the benefit for a fraction of the cost; this plan's per-viewer
  accounting is the substrate simulcast would build on if ever done.

## Where it lives

- Fairness/attribution decisions, audio chains, throttle mechanics:
  `TailscreenKit/Sources/TailscreenSharer/TailscaleScreenShareServer.swift`,
  `CongestionControl.swift`.
- Roster health: `ViewerHealth`, surfaced through `MenuBarView.swift`
  (row-per-viewer with a health dot; the old single summary line is gone).
- Constants (`maxQueuedAudioPacketsPerViewer`, etc.) live in
  `TransportTuning`, pinned by `QualitySettingsTests`.
- Tests: `PerViewerFairnessDecisionTests`, `ViewerLifecycleDecisionTests`.
- Protocol/PLI/keyframe cadence background: `.claude/rules/protocol.md`.

Referenced from `plans/share-by-token.md` (per-viewer bitrate adaptation) —
that reference is satisfied by the shipped `fairnessDecision`/congestion
control described above.
