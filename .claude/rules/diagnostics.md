---
paths:
  - "Packages/TailscreenKit/Sources/TailscreenProtocol/Diagnostics/**"
  - "Apps/macOS/Sources/AppDiagnostics.swift"
  - "Apps/macOS/Sources/DiagnosticSurface.swift"
---

# Session diagnostics

The recorder, the bundle format, and the cross-side merge. All portable —
`Packages/TailscreenKit/Sources/TailscreenProtocol/Diagnostics/`, tier 1, so
Linux CI runs every test.

## Why it exists

One side's log answers "what did my machine do"; the pair answers "what
happened". A viewer that gave up waiting and a sharer that never saw the
HELLO look identical, from one side, to a sharer that parked it on an unread
approval prompt — different bugs, same single-side symptom. The merge is the
feature; the recorder makes it possible.

## The pieces

| File | What it owns |
|------|--------------|
| `DiagnosticEvent.swift` | The event value type, `DiagnosticRole`/`Category`/`Severity`/`Value` |
| `DiagnosticEventName.swift` | **The registry** — every event name, its category + default severity |
| `DiagnosticsRecorder.swift` | The buffer (prologue + ring), the switch, thread safety |
| `DiagnosticsRedaction.swift` | What never reaches a bundle, applied on the way IN |
| `DiagnosticsBundle.swift` | The JSONL file format, header, tolerant parse |
| `DiagnosticEvent+Codable.swift` | On-disk shape of one event line |
| `DiagnosticsMerge.swift` | Interleaving two sides + clock-skew correction |
| `DiagnosticsExport.swift` | Filenames, the write, the rendered timeline |
| `AudioDeviceDiagnostics.swift` | Which audio devices existed / were selected, and when that changed |
| `DiagnosticsPreference.swift` / `ReleaseChannel.swift` | On-by-default-in-RC rule |
| `DiagnosticsCenter.swift` / `DiagnosticsHost.swift` | Process recorder, bring-up, switch, export |

## Hard rules

- **Event names are a registry, like wire bytes.** Add a case in the same commit as the code recording it; never rename or reuse a shipped one (`DiagnosticEventNameTests` pins the set). Retire by no longer recording, not by deleting the case.
- **Category/severity come from the name, not the call site** — two call sites recording one event under different categories breaks any filter on it. Severity override on `record` is only for events whose weight genuinely depends on outcome.
- **Record decisions, not packets.** Handshakes, admission, user actions, view changes, failures — things you'd mention describing what happened. Per-packet traffic is summarized by counters instead (see `transport.summary` below).
- **Fields are flat scalars, no nesting** — greppable, joinable across sides, and keeps a Chrome-Trace/OTLP exporter additive later.
- **Never record a secret at the call site; `DiagnosticsRedaction` is the second line**, scrubbing every string value on the way in (free-text fields come from code with no idea it's feeding a recorder). Tailnet IPs and device names ARE recorded deliberately — that's what merges bundles and makes them legible; the bundle header discloses this. The scrubber's three transforms (share token, login-URL path, auth key) run in **sequence**, never first-match-wins — one value can carry two credentials. The URL step keeps the sign-in URL's **origin** (real, non-secret info) but still lets an origin-only/exempted URL fall through to the auth-key scan. It measures the path with anything an earlier step already redacted **subtracted out**, so a share-link fingerprint survives while a token embedded in a login URL doesn't.
- **Never `Synchronization.Mutex`** (repo-wide rule, see CLAUDE.md) — these types hold a bare `NSLock` as the sanctioned carve-out, not an exception, because `DiagnosticsRecorder` releases its lock early inside `record` and `DiagnosticsBundle` guards two separate statics, neither of which fits one scoped `withLock`.

## Record availability, not just selection

"They couldn't hear me" splits into "wrong device selected" vs. "right device
never appeared in the list" (driver/permission/hot-plug — unfixable in-app).
`audio.devices.changed` carries both device lists, both counts, and both
selections, and fires on **change** (lists compared as ordered, since a
reorder means the system default moved), not on every enumeration. `selected_*`
(user's choice, possibly "system default") and `effective_*` (what that
resolves to) are both recorded, because the interesting case is exactly when
they diverge; the system default is part of the change-detected snapshot
because macOS moves it on its own (headset plug-in, System Settings change).
Turning recording **on** must clear the cached snapshot and re-baseline, or a
cache warmed while recording was off makes every later enumeration compare
equal and nothing is ever recorded. The mic toggle enumerates before recording
`mic.attached`/`mic.failed`; a viewer toggling mic from the viewer window opens
neither the Settings nor sharer-tool picker, so it must also enumerate, or that
bundle carries no device inventory at all (`device=unknown`, 0.10.0-rc.14).
Devices are recorded **by name**, never `AudioDeviceID` (reboot-local handle,
meaningless to a reader).

## Media quality: milestones + one summary per window

**Record milestones in the portable `ViewerSession`, not per host,** so mac/GTK/WinUI say the same things through one suite (`ViewerSessionDiagnosticsTests`): `decode.first_frame` (with `ms_since_ack`), `render.size.changed`, `decode.failed`, `decode.recovery.action` per rung, `video.stalled` at the terminal rung. Exception: the mac ladder runs inside `VideoDecoder` off-session, so `TailscaleScreenShareClient` records its own rungs with identical names/fields, funneling per-frame failures through `noteHostDecodeFailure` (counting-only) so `decode_failures` still comes from one place.

**Frame decode callbacks write a mailbox; the receive side drains it.** `VTVideoDecoderAdapter` decodes off-queue from the receive task, so `noteDecodedFrame`/`noteHostDecodeFailure` only touch a `Guarded` mailbox, and `drainFrameMailbox` (called from every receive-side entry point) applies the batch — a decoder callback must never touch session state directly, or it's a data race.

**`transport.summary`: one event per ~5s sampler window, on both sides, always** — even an all-zero window, because a silently-vanished feedback path used to look identical to a clean one when only "something nonzero" got logged. Sharer side is the pure `TailscaleScreenShareServer.transportSummaryFields` (`SharerTransportSummaryTests`); carries `rr_received`/`rr_age_ms`/`rr_fresh` **undecayed** (the congestion sweep decays a stale report to "no loss" for its own purposes — the record must not inherit that lie). `window_ms` is measured, never assumed nominal, on both sides. Sampling starts only after admission (an SSRC exists) so a viewer parked on approval doesn't pre-fill rows of zeros.

**`audio.summary`** mirrors it one release later, from the pure `VoiceStats.audioSummaryFields` (`AudioSummaryTests`), on mac `VoiceChannel` and portable `VoiceDownlink`. Carries what was playing (`voice_streams` per-window, not sticky; `system_audio`, `mic_on`, `jitter_target`, `output_device`) because zero counters mean nothing without knowing what should have produced sound; separates system-audio clipping from voice clipping; **omits** (never zeros) `overruns`/`underruns` on a host with no playback queue — a false zero reads as "nothing dropped" instead of "nobody counted". Row recorded for every window audio is running, whether or not a counter moved — but a window with no audio activity at all records nothing (the lifecycle events already say audio should be running). Sharer's row also carries `audio_packets_in`/`audio_rejected_in` (inbound viewer audio) since every other field describes outbound-only traffic.

**`annotation.summary` inverts the clean-window rule on purpose**: recorded only for a window where an annotation actually crossed the wire (`applied`/`dropped`/`relayed`), because annotations are discrete acts — a silent window means nobody drew, and a row per empty window would flood the ring for a rarely-used feature.

**`decode.failed` fires once per episode** (first failure after a decoded frame; total in `failures_total`); `decode.recovery.action` bounded by the ladder's own latch (4 rungs, each once).

## Buffer & ordering internals

- **Two buffers, not one ring.** A plain ring evicting oldest-first deletes the handshake and keeps the symptom. A **prologue** (first 256 events, never evicted) + a **ring** (most recent 4096); drop count is exported and rendered as a marker at the hole (`DiagnosticsMerge` finds it from a discontinuity in `seq`, which is dense by construction).
- **One prologue per SESSION, not per process** — a process-wide prologue fills on the first share and every later session's HELLO lands in the evictable ring. Hosts call `recorder.beginSession()` at share start/connect; last 4 sessions retained, and calling it twice back-to-back (failed start + retry) is one session.
- **Every event carries its session ordinal**, exported, never renumbered on eviction (a bundle starting at session 2 says so rather than erasing it). Scoped to one bundle only — cross-machine pairing is still the handshake SSRC.
- **`events()` sorts by `seq`, never concatenates prologue+ring** — once a second prologue exists, they interleave in time.
- **`DiagnosticsCenter.recorder` is never nil'd** — turning recording off flips a Boolean inside the (single, process-lifetime) recorder instance, so every holder of the reference stays consistent both ways.

## Switch semantics (easy to get wrong)

- `recordLifecycle` bypasses the enabled-switch for exactly two events: `recording.stopped` (must outlive the stop) and `recording.exported` (export-while-stopped is the documented reproduce→stop→export workflow).
- `record` re-checks the enabled flag **and a generation counter together, under the append lock** — checking the flag alone leaves a race where scrubbing (done outside the lock, since it's expensive) spans a stop/restart and an event from the closed session lands after the next session's `recording.started`.
- **No-op transitions write nothing** — `setRecording` returns early when state already matches, or `TAILSCREEN_DIAGNOSTICS=0` spams `recording.stopped` on every already-disabled toggle and defeats the emptiness check in `export`.
- Marker + switch flip in **one lock acquisition** (`setRecording(_:markerName:markerFields:)`) — as two calls, another thread's event can land before `recording.started` or after `recording.stopped`. Enable writes the marker after the flag; disable writes it before.
- `export` builds the marker into the **outgoing snapshot** (carries the export's own elapsed time, not a borrowed one) and commits it to the live recorder only after the write succeeds, and tests emptiness **before** writing the marker (or the marker itself defeats the "nothing recorded" check).
- `DiagnosticsEnvironment.channel` is **stored, not re-derived from the version string** — a macOS PR artifact's numeric-only plist version classifies as stable by any re-derivation.
- `TAILSCREEN_DIAGNOSTICS` pins the **live** value for the whole run (checked by `setRecording`, not just at `start`) so a harness's env var can't be countermanded by a mid-run UI toggle.

## Surfaces

`DiagnosticSurfaceTracker`: `shown`/`hidden` **count** (a share renders the sharing view in both the main window and menubar simultaneously — the first to disappear must not report the surface gone); `setVisible` is **idempotent**, for the one-of-a-kind viewer `NSWindow` (repeated `orderFrontRegardless` on refocus must not accumulate). The table persists across the recording toggle, and turning recording **on** must replay it (`replayVisible()`) — nothing re-fires `onAppear` just because a switch moved, so without the replay the first surface on screen when recording starts is invisible to the bundle.

## The clock problem

Two machines' wall clocks disagree; sorting raw timestamps can show an ack
before its message. `tailscreen-diagnostics-merge` (`make merge-diagnostics
FILES="a.jsonl b.jsonl"`, built from `TailscreenProtocol` alone — no
`libtailscale.a`/Go/libopus, so triage needs no build prerequisites) is the
tool; behavior is pinned by `DiagnosticsBundleTests`/`DiagnosticsExportTests`.

`DiagnosticsMerge` solves the offset via the NTP formula `((t2-t1)+(t3-t4))/2`
using the four HELLO/HELLO_ACK timestamps, paired on the **SSRC the sharer
assigns in HELLO_ACK** (already on the wire, nothing added). Always reported
in `clockNotes`, never silently applied. Things it must get right:

- **One ack per join.** `registerOrRefresh` proactively acks a re-registering (KEEPALIVE) viewer, but a fresh HELLO join gets a second ack from the HELLO handler too — idempotent for the viewer, not for the record (viewer stamps off whichever ack arrives first, sharer stamps the second), which can make round-trip negative. Proactive ack is gated on `!isNew`.
- **Scope pairing to the ack's own session** — `last(where: seq <= ack)` must not walk past a session boundary into a stale HELLO from a previous share. Refusing to align beats a confidently wrong offset.
- **Pair the sharer's HELLO by `addr`, not just recency** — with several viewers joining at once, the latest `hello.received` before an ack is often a different viewer's retry.
- **Replay each side from one anchor + its own `monotonicNs`**, never per-event wall clock — an NTP step mid-session must not reorder one machine's own events against each other.
- **Compare `seq`, not wall clocks, for within-bundle "which HELLO preceded this ack"** — a backward wall-clock step between `hello.received` and `hello.ack.sent` would wrongly exclude the legitimate HELLO. Only the four formula timestamps stay wall-clock (the offset is a statement about wall clocks); selection must not be.
- **Anchor replay at the handshake, not `startedAt`** — the offset already accounts for any clock step before the handshake; anchoring earlier reintroduces the discontinuity. `startedAt` is the fallback only when no handshake completed.

Pairing derives from **events, not header roles** — one process can be sharer and viewer at once, so the header's role is a default, not a fact.

## Host wiring

`DiagnosticsHost.start(environment:)` at startup (all three hosts);
`setRecording`/`export`/`merge` (macOS only today — Linux/Windows have no
settings pane yet, switch via `TAILSCREEN_DIAGNOSTICS`, see
`docs/platform-support.md`). `merge` lives in the portable host (not the mac
app) because it's not mac-specific and is pinned by `linux-protocol` on every
PR; it records nothing itself (derives a file, writes no marker) and skips the
local recording when it has no events.

App-level events (`action.*`, `view.*`, `fault.surfaced`) are **macOS-only** —
`AppState`/`SettingsView`/the surface modifier have no GTK/WinUI equivalent, so
non-mac bundles explain the connection but not the person.

Per-host wiring is `recorder.beginSession()` + wiring the recorder into the
server/client at construction (`LinuxShareSession`, `WindowsShareSession`, mac
`AppState`, `TsnetTransport`) — skipping `beginSession` still records, it just
loses eviction protection for that session's handshake, silently.

`PrintLogSink` tees every package log line as `log.line` for free (~35 call
sites, untouched). `TsnetTransport.StderrLogger` tees separately because
viewer executables reserve stdout for the data path — without it, GTK/WinUI
viewers had no package log lines at all. These are prose, a safety net
**under** the named registry events, never a substitute — promote a
load-bearing log line to a registry event instead of relying on it.

**The app's own `TSLogger`s tee individually, most still don't.** Only
`TailscaleScreenShareClient`'s and `VoiceChannel`'s tee; `VideoDecoder`,
`VideoEncoder`, `HelperScreenCapture`, `ViewerApproval`, `GlobalHotkey` are
stdout-only. Tee one when a bundle needs it, don't sweep.

**Identity must never reach the tee.** `PrintLogSink(prefix: "Auth",
capturesDiagnostics: false)` opts the whole `TailscaleAuth` sink out (it only
ever logs account names in prose, which redaction can't distinguish from a
device name). `TsnetTransport`'s single `StderrLogger` mixes an identity line
with node-bring-up lines a bundle needs, so it's gated **per call**
(`logWithoutCapture` vs. ordinary `log`) instead. Auth state is recorded via
`node.signin.*` registry events instead, which carry state without identity.
Any new sink logging an identity the bundle header disclaims needs the same
treatment.

## Formats

JSON Lines: greps, streams, truncates safely, diffs, human-legible. Parser is
tolerant of everything except schema — unknown event names/categories/corrupt
lines are skipped (a reader rejecting a newer build's bundle fails exactly
when needed); `Header.currentSchema` above the reader's own is refused
(`unsupportedSchema`), older schemas stay readable.

If this grows: Chrome Trace Event Format (Perfetto, cross-process flow
events) or OpenTelemetry/OTLP (proper correlation via W3C Trace Context) both
fit — OTLP is the better endgame but needs a trace ID on the wire, i.e. a
registry row + spec appendix + conformance vector, deliberately not done yet.
A Wireshark dissector from `docs/spec.md` is a separate, valid idea but solves
a different problem (packet-level, no "user clicked Stop Sharing"). Flat
scalar fields keep either exporter additive.
