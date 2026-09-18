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
| `AudioDeviceDiagnostics.swift` | Which audio devices existed and which was selected, and when that changed |
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

The scrubber's three transforms — share token, login-URL path, auth key — run
in **sequence** over one value, never first-match-wins. One value can carry two
credentials (`token=tc…&authKey=tskey-auth-…`), and returning on the first left
the second verbatim: the guarantee is about the value, not about whichever
credential happened to appear first. The URL step keeps the **origin** of a
sign-in URL (which control server was used is a real answer, and it is not the
secret) and exempts the app's own docs links, but an exempted or origin-only URL
still reaches the auth-key scan — `https://tailscreen.dev/install?authKey=tskey-auth-…`
is why "removed wherever embedded" can have no exception.

One subtlety in that sequence: the URL step measures the path with anything an
earlier step already redacted **subtracted out**. A share link's path
(`…/view/#tc:9f21…`) is long only because the fingerprint is sitting in it, and
replacing the path wholesale would throw away the one value that lets two
bundles show they used the same link; a login URL that also carried a token has
an opaque `/a/<secret>` left after the subtraction and is still redacted.

**Never `Synchronization.Mutex`** — and that is a repo-wide rule now, not a
`Diagnostics/` one. TSan learns happens-before from
the pthread primitives it interposes on, not from `Mutex`'s futex, so it reads
every `withLock` body as an unsynchronised access and reports a race on correct
code; the cost that matters is that a `Mutex`-guarded type cannot be checked by
the sanitiser **at all**, which is exactly wrong for a recorder written to from
the capture callbacks, both UDP receive loops, the sweep timers and the UI
thread. `Guarded` (tier 1) packages an `NSLock` behind `Mutex`'s
`withLock { $0 … }` shape and is the default; `Guarded.swift` carries the full
argument and `.claude/rules/testing.md` the reproduction. The types here hold a
bare `NSLock` instead, which is the carve-out rather than an exception to the
rule: `DiagnosticsRecorder` releases its lock early in `record` and
`DiagnosticsBundle` guards two separate statics, and neither shape fits a
single scoped `withLock`. Both are still NSLock-backed, so both are visible to
the gate — which is the whole point.

## Record availability, not just the selection

"They couldn't hear me" has two causes that look identical from outside: the
right device was in the list and the wrong one was selected, or the right
device was **never in the list** and could not have been selected. The second
is a driver, permission or hot-plug problem that no amount of clicking in
Tailscreen would have fixed, and recording only the selection is silent about
it. So `audio.devices.changed` carries both lists, both counts, and both
selections.

It fires on **change**, not on enumeration: the host enumerates whenever a
picker is about to render, many times a session and almost always with the same
answer. Change is also the more informative trigger — a Bluetooth headset
dropping out mid-session is invisible to the user beyond "it stopped working",
and the line saying the device left is the whole diagnosis. Lists compare as
ordered, not as sets, because a reorder means the system default moved, which
changes what an unselected pick resolves to.

`selected_*` and `effective_*` are both recorded and answer different
questions: `selected` is the user's choice (possibly "system default", meaning
they chose nothing), `effective` is the device that choice resolves to. The
expensive case is `selected` reading "system default" while `effective` is not
the device the person assumed, which neither field answers alone. The system
default is part of the `Snapshot` — and therefore of change detection —
because **macOS moves it on its own**: plugging a headset in, or a change in
System Settings, shifts what an unselected pick uses with the device lists
completely unchanged.

Turning recording **on** clears the cached device snapshot and re-records a
baseline. Without that, the commonest flow loses the inventory entirely:
Settings opens (enumerating and warming the cache) while recording is off, the
event is dropped, the user turns recording on right there, and every later
enumeration compares equal and records nothing.

Devices are recorded **by name**, never by `AudioDeviceID`: the ID is a
machine-local CoreAudio handle that changes across reboots and means nothing to
a reader, while the name is what the person saw in the picker and what they
will say when describing the problem.

## Two things that look like bugs and are not

**The buffer is two buffers.** A plain ring keeps the most recent N events and
drops the oldest, which here deletes the answer and keeps the complaint — the
handshake is in the first two seconds and the symptom arrives an hour later. So
a **prologue** (first 256 events, never evicted) sits in front of a **ring**
(most recent 4096), with the drop count between them exported rather than
swallowed — and rendered, which is a separate thing and was the part missing.
`DiagnosticsMerge` finds each hole from a **discontinuity in `seq`** (dense by
construction, so a jump says not just how many events are gone but *where*,
including the leading case of a whole released prologue) and
`renderTimeline` prints a marker in place, immediately before the first
surviving event. A total in a header nobody reads does not stop a reader
drawing a causal line straight across the hole, which is the one failure the
counter exists to prevent.

There is **one prologue per session**, not one per process, and the last four
are retained. A single process-wide prologue quietly stopped protecting
anything the moment the app was used twice: it filled during the first share,
so every later session's HELLO landed in the evictable ring, and a long-running
app could export a bundle missing exactly the events the merge pairs the two
sides on. Hosts open one with `recorder.beginSession()` — mac `AppState` at
share start and at connect, `LinuxShareSession`, `WindowsShareSession`,
`TsnetTransport` — and calling it twice with nothing in between is one session,
because the start paths can run back to back on a failed start and a retry.
A released prologue's events are counted into `droppedCount` like any other
eviction.

**Every event carries its session ordinal**, and it is exported. Without it the
stream is one undifferentiated run: a reader cannot tell where the share that
went wrong began — and "easy to follow" is the whole point of the format. The
ordinal survives the retention cap rather than being renumbered down, so a
bundle whose lowest session is 2 says two sessions were released instead of
erasing that. It scopes to ONE bundle: the two sides number their sessions
independently, and what joins them across machines is still the SSRC in the
handshake. `renderTimeline` marks each boundary, per device and only on a
change, so a single-session bundle says nothing about sessions at all.

That split is also why `events()` **sorts by `seq`** rather than concatenating
the two containers. Once a second prologue exists they interleave in time —
session one's tail is in the ring, session two's opening events are in a
prologue recorded after it — and concatenation would print the second
handshake before the first session's last events.

**`DiagnosticsCenter.recorder` is never set back to nil.** Turning recording
off moves a Boolean *inside* the recorder instead. The sharer server and the
viewer session copy that reference when they are constructed; nil'ing it would
leave them holding a stale copy and still recording, while turning it back on
would install a reference nothing already built would ever see. One object for
the life of the process, a Boolean inside it, and both directions work
everywhere at once.

## Two events bypass the switch

`recordLifecycle` appends even while recording is off, and exactly two events
use it: `recording.stopped`, which has to outlive the stop it reports, and
`recording.exported`, because **exporting while stopped is the documented
workflow** — reproduce, stop, hand the file over. An ordinary `record` no-ops
when disabled, so that workflow produced a bundle with no record of its own
export. It is deliberately not implemented by flipping the switch on and back:
that would open a window for every other writer in the process to land an event
the user asked not to be recorded. `export` also tests emptiness BEFORE writing
the marker, or the marker is what makes the bundle non-empty and the
"nothing recorded" guard can never fire.

`record` reads the switch **and a generation counter** together, and requires
both to still hold when it takes the append lock. Re-checking `enabled` alone
does not close the off→on race: fields are scrubbed outside the lock on purpose
(scrubbing a long log line is the expensive part), so a writer can be stopped
and restarted while it scrubs, then see `enabled == true` again and append an
event from the closed session after the `recording.started` that opened the next
one — carrying a timestamp from before it.

A **no-op transition writes nothing**: the marker describes a transition, and
`setRecording` returns before appending when the state already matches. Under
`TAILSCREEN_DIAGNOSTICS=0` there is never a transition — every toggle resolves
back to `false` and arrives while already disabled — so without the guard each
flip appended another `recording.stopped`, and `export` then saw a non-empty
recorder for a run that was forced to record nothing. The session-opening marker
is unaffected: `start` writes it through `recordLifecycle`.

The marker and the switch move in **one** lock acquisition
(`setRecording(_:markerName:markerFields:)`). As two calls, a transport or
logging thread can append in between — landing an event before the
`recording.started` that claims to open the session, or after the
`recording.stopped` that claims to close it. Enabling writes the marker after
the flag, disabling before it.

`export` builds the marker into the **outgoing snapshot** (via
`recorder.snapshotStaging(_:)`, so it carries the elapsed time of the *export*
rather than borrowing the previous event's — the merge renders every event at
`anchor + elapsed`, which would otherwise put an export done minutes later back
at that event's moment) and commits it to the live recorder only after the write
succeeds; otherwise a failed write leaves
`recording.exported` behind and the next bundle that does succeed claims an
export that never happened. The filename is uniquified against the directory
too — the stamp has one-second resolution, and a double-click on Export would
otherwise overwrite the first bundle.

`DiagnosticsEnvironment.channel` is **stored, not re-derived from the version**.
A macOS PR artifact is stamped `0.0.<PR>` (the plist demands numeric), which
classifies as a stable release, so a host told by CI "this is a candidate" needs
somewhere to put that. Re-deriving discarded it and left the recorder off while
the Settings toggle, reading the host's own answer, said on.

`TAILSCREEN_DIAGNOSTICS` pins the **live** value for a whole run, not just the
starting one: `setRecording` persists the user's choice but resolves the live
recorder against the override. Applying it only at `start` left a UI toggle able
to countermand a harness mid-run.

## Surfaces: counted or present, never both

`DiagnosticSurfaceTracker` has two entry points and they are not
interchangeable. `shown`/`hidden` **count**, because a SwiftUI surface genuinely
exists twice — while a share is live the whole sharing view renders in the main
window *and* the menubar, so `PendingViewersList` is mounted twice and the first
to disappear must not report the surface gone. `setVisible` is **idempotent**,
for the viewer's `NSWindow`, which is one thing whose visibility is set:
`orderFrontRegardless` runs on every connect and every re-focus while `orderOut`
runs once, so a count there would climb and never return to zero. The window
also reports at those real transitions rather than at construction — it is owned
for the process lifetime and reused, so a marker at construction fires once ever.

The table is kept whether or not anything is being recorded — it has to be, or
the counts would not survive the toggle — so turning recording **on** replays it
(`replayVisible()`, from `AppState.setRecordDiagnostics`). Without that, a
surface that appeared while recording was off is in the table with no
`view.shown` behind it: nothing calls `onAppear` again just because a switch
moved, so the record's first word about Settings — the pane the user is standing
in — would be a `view.hidden` with nothing to match, and the bundle would never
say what was on screen at the moment recording started. It is the same shape as
the audio-device baseline one section up, and it is fixed in the same place.

## The clock problem

Two machines' wall clocks disagree. Sorting two bundles on raw timestamps
produces a plausible-looking lie — an ack before the message it acknowledges —
and a reader will read causality out of the order, because that is what an
ordered list is for.

**Two ways to actually run it**: macOS's **Merge With…** button (see *Host
wiring*), and `tailscreen-diagnostics-merge` — an executable target in this
package (`make merge-diagnostics FILES="a.jsonl b.jsonl"`), which is the
only route on Linux and Windows and the one to reach for when somebody
hands you both bundles. It takes `TailscreenProtocol` alone, so it builds with a bare
Swift toolchain: no `libtailscale.a`, no Go, no libopus, which is what lets
somebody triaging a pair of bundles build it without the rest of the repo's
prerequisites. The tool is deliberately thin — argument handling and naming
the file that failed — because every decision below belongs to the library
and is pinned by `DiagnosticsBundleTests` / `DiagnosticsExportTests`. It
exists because the merge shipped complete, tested, and callable from nothing
but its own suites: two sides could be recorded and exported, and never read
together, which is the only reason to record two sides.

A handshake is exactly the four-timestamp exchange NTP uses, so
`DiagnosticsMerge` solves for the offset with
`((t2 - t1) + (t3 - t4)) / 2` and pairs the two sides on the **SSRC the sharer
assigns in the HELLO_ACK** — a value both ends already know, so nothing had to
be added to the wire. The estimate is always reported in `clockNotes`, never
silently applied: an offset a reader cannot see is as misleading as the skew.

Two things the merge has to get right and can get wrong silently:

- **One ack per join.** `registerOrRefresh` proactively acks a viewer it
  newly added, which is what a NAT/DERP rebind (re-registering via KEEPALIVE,
  not a fresh HELLO) needs to learn its new SSRC — but on the HELLO path the
  handler sends its own ack straight afterwards, so a normal join put two on
  the wire. Idempotent for the viewer, which ignores an ack matching its
  current SSRC; **not** idempotent for the record, because the viewer stamps
  `hello.ack.received` off whichever arrived first while the sharer stamps
  `hello.ack.sent` for the second. That is `t3` and `t4` describing different
  datagrams, and it can make the round trip come out negative and have the
  alignment refuse a perfectly good handshake. The proactive ack is gated on
  `!isNew`.
- **Scope the pairing to the ack's own session.** A session whose HELLO was
  evicted still has its ACK, and `last(where: seq <= ack)` walks straight back
  past the boundary and pairs it with an hour-old HELLO from the previous
  share — an offset out by the whole gap. Refusing to align is right there: a
  confidently wrong correction is worse than none. Note what this does NOT
  fix — sessions are per bundle, so an SSRC that repeats across the two sides'
  independently-numbered sessions is still ambiguous across bundles. Closing
  that needs an identifier on the wire, which is the OTLP trace-context
  endgame under *Formats* and deliberately not today's answer.
- **Pair the sharer's HELLO by `addr`, not just by time.** A share with several
  people joining at once has many `hello.received` interleaved, and the latest
  one before the ack is frequently a different viewer's retry — giving an offset
  that looks plausible and is wrong.
- **Replay each side from one anchor plus its own `monotonicNs`**, never from
  each event's recorded wall clock. A clock can step mid-session (NTP correcting
  a drifting machine is routine), which would reorder one device's own events
  against each other — a causal inversion inside a single machine's story, which
  is the one thing a timeline must never invent. This is what `monotonicNs` is
  recorded for.
- **Compare `seq`, not wall clocks, for the WITHIN-bundle "which HELLO came
  before this ack" tests.** Sequence is exact, local and monotonic by
  construction; the wall clock is the very thing that steps. A backward step on
  the sharer between `hello.received` and `hello.ack.sent` made the legitimate
  HELLO compare later than the ack, so it was excluded and the pairing
  abandoned — on exactly the bundles whose clocks most needed aligning. The
  four timestamps in the formula stay wall clocks, because the offset is a
  statement about wall clocks; only the SELECTION must not be. (The viewer-side
  version of that step is rejected anyway by the negative-round-trip guard, and
  rightly: a `t1` and `t4` on two clock bases make the formula invalid.)
- **Take that anchor from the handshake, not from the session start**
  (`DiagnosticsMerge.anchor(for:)`). The offset is estimated from handshake
  timestamps, so it already contains any clock step that happened before them;
  anchoring at `startedAt` — a reading taken before the step — replays the side
  from a pre-step origin while correcting it by a post-step offset, leaving the
  whole timeline shifted by exactly that discontinuity. `startedAt` stays the
  fallback for a bundle that never completed a handshake.

The pairing is derived from **events, not header roles**. One process can be
sharer and viewer at once (a Mac sharing to one person while watching another),
so the header's role is a default, not a fact about the session.

## Host wiring

`DiagnosticsHost.start(environment:)` once at start-up; `setRecording(_:)` from
the settings toggle; `export(to:)` from the export button; `merge(with:into:)`
from **Merge With…** beside it. **All three hosts call `start`; only macOS calls
`setRecording`, `export` and `merge` today** — Linux and Windows have no settings
pane or file picker yet and switch via `TAILSCREEN_DIAGNOSTICS`
(`docs/platform-support.md` has the matrix); until they do,
`tailscreen-diagnostics-merge` is the way in on those platforms.

`merge` sits in the host rather than in the mac app for the same reason the
others do — it is not mac-specific, and the swift-cross-ui apps inherit it the
day either grows a picker — and, more immediately, because a decision in
`Apps/macOS` is only compiled and tested on the macOS CI leg, whereas one here
is pinned by `linux-protocol` on every PR. Two rules of its own: it records
**nothing** (a merge derives a file from bundles it does not change, so it needs
no marker and no new registry name — exporting is the operation that writes its
own), and it includes the local recording only when that recording has events,
because "somebody sent me both files and this machine was never in the session"
is a real way to arrive rather than a misuse. The ordering inside these is
load-bearing (`recording.stopped` before
the switch moves or the event is itself dropped; `recording.exported` before
the snapshot or a bundle never records its own export), which is why it is
written once rather than three times.

The app-level events (`action.*`, `view.*`, `fault.surfaced`) are macOS-only so
far: they are recorded from `AppState`, `SettingsView` and the surface modifier,
and the GTK and WinUI apps have no equivalent call sites. So a Linux or Windows
bundle explains what the connection did but not what the person did.

Per-host wiring is two lines each at construction — `recorder.beginSession()`,
then `server.recorder = DiagnosticsCenter.shared.recorder` in
`LinuxShareSession`, `WindowsShareSession` and mac `AppState`;
`pipeline.session.recorder = …` in `TsnetTransport`; mac's client forwards its
own into `ViewerSession`. A new host that wires up a recorder and forgets
`beginSession` still records — it just loses the eviction protection on that
session's handshake, silently.

`PrintLogSink` tees every existing package log line into the recorder, which is
where most of the coverage comes from for free (~35 call sites across the
transport and sharer tiers, none of them touched). `TsnetTransport.StderrLogger`
tees too, and has to: it is a second sink only because viewer executables
reserve stdout for the data path, and the GTK and WinUI **viewers** reach tsnet
through it rather than through the print sink — so before it teed, a Linux or
Windows viewer bundle carried no package log lines at all. Those are prose and
therefore the weakest kind of event — a safety net **under** the named
registry events, never a substitute. When a log line turns out to be
load-bearing in an investigation, give it a registry case.

**Two places keep an identity out of the tee, and they use different
mechanisms because the shape of the problem differs.**
`PrintLogSink(prefix: "Auth", capturesDiagnostics: false)` in `TailscaleAuth`
opts the whole sink out — everything it logs is auth prose. That is not
available in `TsnetTransport`, where one `StderrLogger` writes both the
`Connected as <login>` line and the node bring-up lines a viewer bundle needs,
so the exception is per-CALL: `logWithoutCapture` for the identity half, an
ordinary `log` for the tailnet-and-node half. A new log line that names an
account needs one or the other; which one depends on whether its sink logs
anything else worth keeping.

Why either is needed: that sink logs the signed-in account's name in prose.
Redaction cannot help there — it deliberately keeps names, and nothing in free
text distinguishes an account name from a device name — and the bundle header
promises the sender it carries no sign-in details. The auth story is recorded
as `node.signin.*` registry events instead, which carry the state without the
identity. Any new sink that logs an identity the header disclaims needs the
same flag.

## Formats

The bundle is JSON Lines because it greps, streams, truncates safely, diffs,
and is legible to a person deciding whether to send it.

The parser is **tolerant of everything except the schema**. Unknown event names,
unknown categories and corrupt lines are skipped, because a reader that rejects
a newer build's bundle fails exactly when it is needed — the person with the
problem is the one running the newer build. `Header.currentSchema` is the
opposite case by definition: it moves only when an older reader would produce
the *wrong* answer, so a schema above this build's is refused
(`unsupportedSchema`) rather than guessed at. Older schemas stay readable.

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
