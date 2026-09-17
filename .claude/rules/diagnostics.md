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

## What it is for

One side's log answers "what did my machine do". The pair answers "what
happened", which is the question anybody actually has. A viewer that waited
thirty seconds and gave up and a sharer that never saw a HELLO are the same
bundle pair as a viewer that waited and a sharer that saw the HELLO and parked
it on an approval prompt nobody was looking at — completely different bugs,
indistinguishable from either side alone. The merge is the feature; the
recorder is what makes it possible.

## The pieces

| File | What it owns |
|------|--------------|
| `DiagnosticEvent.swift` | The event value type, `DiagnosticRole` / `Category` / `Severity` / `Value` |
| `DiagnosticEventName.swift` | **The registry.** Every event name, and the category + default severity each one carries |
| `DiagnosticsRecorder.swift` | The buffer (prologue + ring), the switch, thread safety |
| `DiagnosticsRedaction.swift` | What never reaches a bundle, applied on the way IN |
| `DiagnosticsBundle.swift` | The JSONL file format, header, tolerant parse |
| `DiagnosticEvent+Codable.swift` | The on-disk shape of one event line |
| `DiagnosticsMerge.swift` | Interleaving two sides, and the clock-skew correction |
| `DiagnosticsExport.swift` | Filenames, the write, the rendered timeline |
| `DiagnosticsPreference.swift` / `ReleaseChannel.swift` | The on-by-default-in-RC rule |
| `DiagnosticsCenter.swift` / `DiagnosticsHost.swift` | The process recorder, bring-up, the switch, export |

## Rules

**Event names are a registry, like the wire bytes.** Add a case in the same
commit as the code that records it; never rename or reuse a shipped one.
`DiagnosticEventNameTests` pins the set, so a rename fails CI rather than
failing a reader six months later. Retiring an event is fine — stop recording
it, keep the case. Its meaning is spent; the string still has to mean what old
bundles say it meant.

**Category and severity come from the name, not the call site.** Two call
sites recording one event under different categories is real, invisible, and
breaks the filter that was supposed to find them. The severity override on
`record` is only for events whose weight genuinely depends on the outcome (a
share phase moving to `failed` versus to `sharing`).

**Record decisions, not packets.** Handshakes, admission, user actions, view
changes, failures. The rule of thumb is that an event should be something you
would mention when describing what happened. `receiveRTP` runs hundreds of
times a second; the counters in `ViewerSession.diagnostics` already summarize
that traffic.

**Fields are flat scalars.** No nesting, ever. A flat event is one row in a
table, greppable with `name=value` and joinable across sides on a bare key.
This is also what keeps an exporter to Chrome Trace Event Format or OTLP a
purely additive change later (see *Formats*, below).

**Never record a secret; scrubbing is the second line, not the first.** No
call site passes a token or an auth key. `DiagnosticsRedaction` then scrubs
every string value on the way in anyway, because free-text fields — a caught
error, a log line through the tee — are written by code that has no idea it
is feeding a recorder. Tailnet IPs and device names ARE recorded, deliberately:
they are what makes a bundle legible and what the two sides merge on. What the
feature owes the user there is disclosure, not redaction, and the bundle header
carries it.

## Two things that look like bugs and are not

**The buffer is two buffers.** A plain ring keeps the most recent N events and
drops the oldest, which here deletes the answer and keeps the complaint — the
handshake is in the first two seconds and the symptom arrives an hour later. So
a **prologue** (first 256 events, never evicted) sits in front of a **ring**
(most recent 4096), with the drop count between them exported rather than
swallowed.

**`DiagnosticsCenter.recorder` is never set back to nil.** Turning recording
off moves a Boolean *inside* the recorder instead. The sharer server and the
viewer session copy that reference when they are constructed; nil'ing it would
leave them holding a stale copy and still recording, while turning it back on
would install a reference nothing already built would ever see. One object for
the life of the process, a Boolean inside it, and both directions work
everywhere at once.

## The clock problem

Two machines' wall clocks disagree. Sorting two bundles on raw timestamps
produces a plausible-looking lie — an ack before the message it acknowledges —
and a reader will read causality out of the order, because that is what an
ordered list is for.

A handshake is exactly the four-timestamp exchange NTP uses, so
`DiagnosticsMerge` solves for the offset with
`((t2 - t1) + (t3 - t4)) / 2` and pairs the two sides on the **SSRC the sharer
assigns in the HELLO_ACK** — a value both ends already know, so nothing had to
be added to the wire. The estimate is always reported in `clockNotes`, never
silently applied: an offset a reader cannot see is as misleading as the skew.

The pairing is derived from **events, not header roles**. One process can be
sharer and viewer at once (a Mac sharing to one person while watching another),
so the header's role is a default, not a fact about the session.

## Host wiring

`DiagnosticsHost.start(environment:)` once at start-up; `setRecording(_:)` from
the settings toggle; `export(to:)` from the export button. All three hosts use
these — the ordering inside them is load-bearing (`recording.stopped` before
the switch moves or the event is itself dropped; `recording.exported` before
the snapshot or a bundle never records its own export), which is why it is
written once rather than three times.

Per-host wiring is one line each at construction:
`server.recorder = DiagnosticsCenter.shared.recorder` in `LinuxShareSession`,
`WindowsShareSession` and mac `AppState`; `pipeline.session.recorder = …` in
`TsnetTransport`; mac's client forwards its own into `ViewerSession`.

`PrintLogSink` tees every existing package log line into the recorder, which is
where most of the coverage comes from for free (~35 call sites across the
transport and sharer tiers, none of them touched). Those are prose and
therefore the weakest kind of event — a safety net **under** the named
registry events, never a substitute. When a log line turns out to be
load-bearing in an investigation, give it a registry case.

## Formats

The bundle is JSON Lines because it greps, streams, truncates safely, diffs,
and is legible to a person deciding whether to send it.

Two standard formats would fit and are worth knowing about if this grows:
**Chrome Trace Event Format** (read by Perfetto; its cross-process *flow
events* would draw the HELLO/HELLO_ACK as an arrow between two swimlanes) and
**OpenTelemetry/OTLP**, which solves the correlation problem properly via W3C
Trace Context — a trace ID propagated on the wire. OTLP is the better endgame
and is deliberately not today's answer: a trace ID on the wire is a wire change,
and in this repo that means a registry row, a spec appendix entry and a
conformance vector. Wireshark is the wrong target — it is packet-oriented and
has no notion of "the user clicked Stop Sharing"; the useful Wireshark idea
here is a separate one, a port-7447 dissector built from `docs/spec.md`.

Flat scalar fields keep an exporter to either format additive.
