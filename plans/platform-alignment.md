# Platform alignment plan

> Status: plan only. The gap list is `docs/platform-support.md`; this is the
> order to close it in, and what not to close.

## What "aligned" means here

Not "identical". Three apps on three toolkits will never render the same, and
some differences are correct forever (see [Deliberate divergence](#deliberate-divergence)).

The bar this plan holds to is narrower and testable:

> **A person moving between platforms should never discover a *decision* they
> cannot make.**

Capabilities may differ in fidelity — software vs hardware encode, 8-bit vs
HDR, one capture backend vs another. But anything that decides something about
a **person** — approve a viewer, deny them, remember that decision, drop them
mid-share, grant control, revoke it — must exist on every platform that can
share at all. That is the same rule the macOS hub and menubar already follow
between two surfaces; this extends it across three apps.

By that bar the biggest gap is not video or audio. It is **Access control**,
where Linux and Windows can admit a viewer and nothing else.

## The three kinds of ❌, and why lumping them together is the mistake

`docs/platform-support.md` is one table of red marks, and reading it as one
backlog is how the cheap items get buried under the expensive ones.

| Kind | Example | Cost | What it needs |
|---|---|---|---|
| **A · Wiring** | Windows viewer can't draw; Linux sharer can't inject | low | the portable piece already exists and is tested — only the host call is missing |
| **B · Capability** | microphone capture, sharer-side drawing surface | high | a new platform shim, from scratch |
| **C · Divergence** | Wayland capture, hardware encode, HDR | n/a | a decision, written down, not a task |

Almost every red mark in the **Interaction** table is kind A. Almost every red
mark that *blocks other rows* is kind B. Sequencing is: clear A first because
it is nearly free, then attack the B items that unblock the most rows, and stop
treating C as debt.

## Phase 0 · Stop advertising what we can't do (days)

Not alignment — correctness. These ship a lie today and are cheap.

**0.1 · The Linux sharer claims annotation support it does not have.**
`SharerModel.swift:128` passes `inputInjector: nil` — correctly withholding
`.remoteControl` — but leaves `rendersAnnotations` at its default `true` while
supplying no overlay. So `ScreenShareCaps.annotations` goes out, every viewer
enables its drawing toolbar, and strokes are relayed to *other* viewers but
never appear on the Linux sharer's screen. **With one viewer — the common case
— drawing silently does nothing.** Passing `false` is one line and makes the
viewer honest immediately; rendering them is Phase 3.

*Shipped as a flipped default rather than a call-site fix — a second host had
the same bug, and withholding by default fixes both without touching either.
1.4 has since made the claim true on a composited session, so the Linux app now
derives the bit from whether it actually built an overlay.*

**0.2 · Audit every conditional capability bit, on every host.**
`ScreenShareCaps` is the app's self-description, and a wrong bit is worse than a
missing feature: the peer's UI stops matching reality and the user blames
themselves. 0.1 is one instance; the class deserves a check. Each host should
derive every bit from something it actually has (a non-nil backend, a real
overlay) rather than from a default.

**0.3 · Confirm the Windows capture border.** `ts_wgc.cpp` never sets
`IsBorderRequired`, so WGC should already be drawing its own. No code — if it's
there, the Windows outline row is done and Linux is the only one left.

## Phase 1 · Close the mirror (weeks) — the best value on the list

Linux and Windows *were* mirror images on interaction — an accident of build
order rather than a design: Linux grew the viewer half first, Windows the sharer
half. Every row below is now closed on both, which is what made this the
best-value phase on the list.

| | Linux has | Windows has |
|---|---|---|
| Draw as viewer | ✅ | ✅ (1.1) |
| Zoom + pan viewer | ✅ | ✅ (1.2) |
| Request control as viewer | ✅ | ✅ (1.3) |
| Render viewers' annotations as sharer | ✅ (1.4) | ✅ |
| Inject granted control as sharer | ✅ (1.5) | ✅ |

Every one of these is kind A. The protocol, the grant gate, the coordinate
mapping, the neutral HID key model, the annotation geometry and the rasterizer
are all portable and already unit-tested on Linux CI. What's missing is the host
call.

- **1.1 – 1.3 · Windows viewer: annotations, zoom + pan, request control.**
  ✅ **Done**, and together rather than separately because they are one surface:
  all three are decided by what a pointer drag means, so splitting them would
  have meant writing that precedence three times.

  It came in far under the estimate, and the reason is the point of this plan:
  **almost nothing new was written.** `TailscreenHubUI` already had
  `AnnotationToolbar` and `RemoteControlBar` for the GTK viewer, `ViewerZoomMath`
  already had the geometry, `WindowsKeyCodeMapping` already had VK↔HID (read in
  the other direction from the sharer's use), and `AnnotationRasterizer` already
  drew strokes. Two more pieces moved into the portable tier on the way — the
  GTK viewer's `AnnotationStore`, which was Foundation-only all along, and its
  letterbox arithmetic, now `ViewerPointerMapping` — so both viewers share one
  canvas and one mapping instead of two that drift.

  Three decisions worth carrying forward:
  - **Annotations are composited into the decoded frame**, not onto a second
    surface. `AnnotationRasterizer.draw` (the no-clear half of `render`) writes
    straight into the BGRA the `WriteableBitmap` shows, so strokes zoom and
    letterbox with the video for free. A XAML canvas or a D2D device would have
    been a lot of platform plus a second transform to keep in sync.
  - **Drawing wins over controlling.** With a tool armed a drag is a stroke, not
    a click. A drag cannot be both, so the precedence has to live somewhere;
    it is one property (`forwardsInput`) rather than scattered through the
    handlers.
  - **Ctrl+wheel zooms; plain wheel scrolls the sharer** while a grant is held.
    Without the split, zooming is unreachable while controlling and scrolling is
    unreachable while not.
- **1.4 · Linux sharer: render annotations.** ✅ **Done.** Closes 0.1 properly:
  `Apps/linux/Sources/CGtkOverlay` is the click-through window — override-redirect
  (GTK4 has neither placement nor keep-above, and an overlay needs both), empty
  input region, cairo ARGB32 fed straight from `AnnotationRasterizer` with no
  conversion. It is also the surface Phase 3's sharer drawing will draw into.
  Two things landed with it that were not in the original scope and are worth
  keeping in mind for 1.5 and Phase 3:
  - **It refuses to exist on an uncomposited X11 session**, because without a
    compositor the window has no alpha and the "overlay" is an opaque black
    rectangle over the sharer's screen. `rendersAnnotations` is then withheld,
    so the failure is a viewer with disabled tools rather than a covered desktop.
  - **`tailscreen --overlay-self-test` is a real CI gate**, not a visual check:
    it draws a red stroke, reads the screen back through the sharer's own X11
    capture, and asserts the chroma. Every way this feature can fail — window
    never maps, compositor ignores it, wrong origin, swapped channels —
    otherwise produces a working share and invisible annotations, with no error
    anywhere.
- **1.5 · Linux sharer: inject control.** ✅ **Done.** `Packages/XTestInjectKit`
  is the XTEST path for X11 (the RemoteDesktop portal for Wayland is Phase 3.3),
  and `SendInputInjector`'s decisions were indeed the model — revoke TOCTOU,
  synthesized button-up, modifiers pressed around each key and unwound in
  reverse, Caps Lock never synthesized, unmappable usages dropped rather than
  guessed. Three things differ enough to be worth remembering:
  - **Keysyms, not keycodes.** An X11 keycode identifies a physical key on the
    machine running the server and is meaningless off-host; a keysym is a
    protocol constant. So `X11KeyCodeMapping` (HID → keysym) is portable and
    tested on CI, and only the final `XKeysymToKeycode` hop needs a display.
  - **Scrolling is buttons.** X11's core protocol has no wheel value — a scroll
    is a press/release of button 4/5/6/7, once per notch — so a delta becomes a
    repeat count, with a clamp so a peer's absurd delta can't become a million
    synthetic clicks.
  - **Nothing is injected without an explicit flush**, which is the single most
    likely way for the whole path to look broken while every unit test passes.
    `xtest-probe --live-check` covers it against a real Xvfb.

**Do 1.4 before 1.1.** Fixing the sharer that lies is worth more than adding a
viewer feature, and it unblocks the honest version of the capability bit.

*Phase 1 is complete. The mirror is closed: every row above is ✅ on all three
platforms, and the remaining gaps are Phase 2's access control and Phase 3's
capability shims.*
*With 1.4 and 1.5 done, the Linux sharer half is complete and the table above
is no longer a mirror: what remains is the three Windows **viewer** rows.*

## Phase 2 · Access control, where the "decision" bar actually bites (weeks)

Three rows, all Linux ❌ Windows ❌, and by this plan's definition the most
serious gap in the matrix — a sharer on Linux or Windows can let someone in and
then has no way to change their mind.

- **2.1 · Portable access-policy store.** `ViewerAccessPolicyStore` is
  macOS `UserDefaults`-backed. Make it portable exactly as `AccountProfileStore`
  was: a pure store plus an injected layout, so Linux CI tests the Windows
  layout. The *decisions* (`admissionDecision`, `drainDecision`,
  `connectedDenyList`, `canAcceptPending`) are already portable and tested — only
  persistence is mac-bound.
- **2.2 + 2.3 · Remembered allow / "Deny & Block", and kick a connected
  viewer.** ✅ **Done**, and together because they are one surface: the sharing
  card's roster, which before this was a list of IP strings. Three pieces, each
  where it belongs:
  - `ViewerRosterDecision` (portable) — what a row can offer, and the queue for
    a decision made before the peer's StableNodeID resolves. macOS had grown
    that queue inline in `AppState`; this is the same behaviour, tested.
  - `SharerAccessCoordinator` (TailscreenSharer) — remember, forget, drain the
    queue on each roster tick, push the map at the live server. Reaches the
    server through a closure specifically so every case is testable with no
    tsnet node, no network and no share.
  - `HubViewerRow` + `HubViewerRowView` (TailscreenHubUI) — one component, both
    hosts, per the #177 lesson about putting a decision on every surface.

  Two things worth remembering. **A decision made before the identity resolves
  is queued, not dropped** — the store is keyed by StableNodeID, that arrives
  asynchronously from the sharer's own netmap lookup, and a sharer who wants
  somebody gone wants it now; the row says it is waiting rather than appearing
  to do nothing. And **the queue is pruned when a row leaves**, or a Deny &
  Block on a peer that disconnects before resolving lands on the next
  connection from that address — which behind one NAT is a different machine.
- **2.4 · Ask a peer to share.** ✅ **Done**, and it completes Phase 2. The wire
  pair was indeed portable and pinned; what was missing turned out not to be UI.

  **Neither host was listening.** `TailscaleScreenShareServer` builds a control
  listener when the caller supplies none — but only for the share's lifetime,
  and an ask to share arrives precisely when a machine is *not* sharing. So
  port 7447 answered nothing while idle and every ask read to the asker as
  "no answer", indistinguishable from a peer being away. Both apps now own a
  listener for as long as their node is up and hand *that* one to the share,
  which is also what stops a second listener contending for the port.

  Three pieces moved into the portable tier on the way, and the first is the
  one worth remembering:
  - `ShareRequestInbox` — the coalescing and the cap. macOS had both, inside an
    `import AppKit` file, which is why the other two hosts had neither. The
    dedupe key is the requester's **source IP**, never the hostname in the
    payload: a peer picks its own hostname, so keying on it lets one machine
    stack sixteen rows and pin sixteen connections on the asker's side just by
    varying a string. `ShareRequestInboxTests` asserts exactly that, and fails
    loudly when the key is swapped back.
  - `TailscreenRequestToShareClient` — the parked dial, lifted verbatim from
    the macOS service. Nothing in it was ever platform-specific.
  - `SharerDetail.onAskToShare` — one optional closure, so a host with nothing
    to ask through renders no button rather than an inert one.

  Two smaller decisions. Accepting **pre-approves the asker's IP** before the
  share starts, or the person just invited arrives at this machine's own
  approval gate and is asked to wait — the same peer, prompted twice, seconds
  apart. And the ask is offered only to a machine that is *not* already
  sharing: "ask them to do the thing they are doing" is a banner on somebody's
  desk for nothing.

## Phase 3 · The capability gates (months)

Kind B. Sequenced by how many rows each unblocks.

- **3.1 · Microphone capture** — the single highest-leverage item, unblocking
  three rows on two platforms: *speak*, *mute from outside the window*, and the
  *mute hotkey*. Everything downstream already exists and is CI-tested: Opus
  codec, framing, jitter buffer, concealment, SSRC relay. What's missing is
  capture and the hookup. ALSA/PulseAudio in on Linux, WASAPI capture on Windows
  (the render half already exists in `WASAPIKit`).
- **3.2 · Sharer-side drawing surface** — unblocks *toggle drawing* and
  completes 1.4. On Windows this cannot be `WinOverlayKit`'s window:
  `WS_EX_TRANSPARENT` is load-bearing while drawing is *off* or it swallows
  every desktop click, so local drawing needs a second, non-transparent surface.
- **3.3 · Linux ScreenCast portal** — the highest-leverage *Linux* item, because
  it unblocks three rows at once: share a single window, share an app, and
  **Wayland capture at all**. Today the sharer gates on `$DISPLAY` and sees only
  the XWayland root, so native Wayland windows never reach viewers.
- **3.4 · Change source mid-share, preview thumbnail** — smaller, and both
  become easier once 3.3 exists on Linux.

## Phase 4 · Hub parity, which is cheap by construction (weeks)

Linux and Windows share `TailscreenHubUI`, so each of these is **one change for
two platforms** — the best ratio in the plan and a good place to put spare time.

- **4.1 · Peer detail: route, latency, ACL tags.** ✅ **Done**, and it cost
  almost nothing, which is the thesis of this phase. All three inputs already
  existed and were being thrown away: `TailscalePeerDiscovery` parses `curAddr`
  and `relay` off the LocalAPI seed, `DiscoveredSharer` simply dropped them;
  `tags` were already carried for the filter menu; and the latency is the
  *existing* metadata sweep timed, since that sweep is already a TCP round trip
  over the live path. One clock read, not a second dial — and no probe on a
  round trip that never completed, which would read as a fast link to a machine
  that is gone.

  `PeerRoute` and `ConnectionQualityTier` moved from `Apps/macOS/Sources/` into
  `TailscreenProtocol` **and the macOS copies were deleted, not duplicated** —
  a new public type in that tier lands in macOS's namespace through
  `ProtocolReexports`, so leaving both would be the `ProfileStore` ambiguity
  again. (This is the second time that hazard bit in one sitting; see 2.4.)

  One deliberate divergence from macOS: the quality tier is spelled out in
  words next to the number rather than shown as a coloured dot. macOS puts the
  meaning in a tooltip, which its own accessibility rule says doesn't count —
  and swift-cross-ui has no tooltip to hide it in anyway.
- **4.2 · Quality settings UI.** ✅ **Done.** The model, its clamps, its preset
  mapping and its persistence were portable and tested already, so this really
  was just the control — `HubQualityMenu` on the share card, one component for
  both hosts.

  It is a **menu of checked rows rather than a `Picker`**, which is where the
  guessing stopped and the reading started: swift-cross-ui's `Picker` labels
  its options by string-interpolating the value (`options.map { "\($0)" }`), so
  a `Preset` would render as `low` / `balanced` / `high` — enum case names, in
  a user-facing control — and its availability is backend-conditional. A menu
  of `Toggle`s is what `HubFilterMenu` already proves both backends render.
  The rows are radio-shaped: picking one selects it, un-picking the active one
  does nothing, because "no preset" is not a state this model has.

  The honest part is the caption. Both non-mac capture backends take their
  settings **at construction**, so a change made mid-share does nothing until
  the next one — the card says "Applies to your next share" rather than
  offering a control that appears to work. macOS re-pushes through its
  helper-restart path; neither of these hosts has one, and inventing one was
  not this item.
- **4.3 · Connection stats overlay.** ✅ **Done**, which completes Phase 4.
  `StatsHUD` already existed and the GTK viewer already showed it; what was
  missing on Windows was the *numbers*, not the component.

  The fps accounting behind them was inline in the GTK sink, so it moved to
  the portable tier as `FrameRateCounter` — same reasoning as `I420Converter`
  and `MonoPCMConverter`: arithmetic every renderer backend needs, no backend
  can test in place, one copy per host otherwise. Writing the tests
  immediately found a defect the inline version had carried all along: the
  window start used `0` as "not started", and zero is a legitimate timestamp.
  The GTK sink survived it only because `DispatchTime.now()` never returns 0 —
  a property of the caller, not of the arithmetic.

## Phase 5 · Sharer surfaces

Has its own plan — `plans/sharer-surfaces.md`, with a status table. Notifications
on Linux and Windows, the Linux capture outline, and hotkeys on both. Sequenced
there; listed here so the two plans don't drift.

Note the dependency: its *mute* and *draw* toggles are gated on 3.1 and 3.2.
The surfaces are cheap; two of their contents are not.

## Deliberate divergence

Written down so they stop reading as backlog. Each is a decision, revisitable on
evidence, not a task nobody got to.

| Not doing | Why |
|---|---|
| Hardware encode off macOS | VAAPI/NVENC/Media Foundation are real work for a *performance* win, not a capability gap. Revisit when software encode is the measured bottleneck, not before. |
| HDR / 10-bit / wide gamut off macOS | Capability-gated and off by default even on macOS. Colour rides the SPS in-band, so adding it later needs no wire change — which is exactly why it can wait. |
| A menubar/tray item on Linux and Windows | Already decided against in `plans/sharer-surfaces.md`: notifications + a capture outline cover the ground, and stock GNOME won't draw a StatusNotifierItem without a shell extension. |
| Localized strings off macOS | No demand yet. `ShortcutCatalog` and `SharerNotice` already carry English source text hosts can localize, so the seam exists when it's wanted. |
| Wayland *before* the portal | Not a separate task — 3.3 is the answer to it. |

## Order, and why

```
Phase 0  (days)    stop lying                     ── independent, do now
Phase 1  (weeks)   close the mirror               ── highest value / risk
Phase 2  (weeks)   access control                 ── the "decision" bar
Phase 4  (weeks)   hub parity                     ── 1 change → 2 platforms
Phase 3  (months)  capability gates               ── unblocks Phase 5 contents
Phase 5            sharer surfaces                ── own plan
```

Phases 1, 2 and 4 are parallelisable — different files, different hosts. Phase 3
is the long pole and should start in the background early, because 3.1 and 3.2
gate the most-wanted items in Phase 5.

## How to know it's working

- **`docs/platform-support.md` is the scoreboard.** Every phase updates it in
  the same commit. A row that flips without the matrix flipping is how the doc
  became wrong in Tailscreen's favour once already.
- **Every ❌ that closes should close a *decision* first.** If a phase lands
  without moving a row in Access control or Interaction, ask whether it was the
  right phase.
- **Capability bits must stay honest.** After 0.2, a host advertising a bit it
  can't back is a regression, not a gap — worth a test that derives each bit
  from a real backend rather than a default.
