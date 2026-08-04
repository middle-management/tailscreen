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

  *Landed: the capture backends (`ALSA.PCMRecorder`, `WASAPI.Recorder`), the
  portable seam and pipeline, and **both halves wired end to end** — a viewer
  can unmute and be heard, a sharer can speak to every viewer and hear them
  back. Two mic controls, both from shared chrome: `MicrophoneButton` over the
  video for the viewer, and the same button on the share card for the sharer.
  Both remaining rows — `mute from outside the window` and the `mute hotkey` —
  then landed as **one** thing, because on these two platforms they are one:
  a system-wide chord (⌃⌥M, from `ShortcutCatalog`) held by
  `Packages/X11HotkeyKit` (`XGrabKey`) and `Packages/WinHotkeyKit`
  (`RegisterHotKey`). A tray icon would be the other way to mute from outside
  the window; it is a much larger feature and is deliberately NOT part of this
  — the hotkey closes the row on its own, and half a tray icon would close
  neither.*

  Four decisions from the hotkey work.

  - **One chord, and the SHARER's microphone wins when both are live.**
    These apps can share and watch at once and the two mute latches stay
    separate on purpose, so a single chord has to choose. Flipping both was
    rejected outright: a toggle over two independent latches has no meaning
    when they disagree, and re-defining it as "mute everything" fixes the mute
    direction while breaking the other — the second press unmutes you into a
    call you were only listening to. The sharer wins because *being outside the
    window is not symmetric*: while sharing you are necessarily in some other
    app, so the mic button is behind what you are demonstrating, whereas while
    watching the video window is the thing you are looking at. The viewer gets
    the chord only when no share is running. `MuteHotkeyRouting` is the whole
    decision, and the honest cost — starting a share silently retargets the
    key — is announced rather than hidden.
  - **A grab that was refused must not read as a grab.** Both platforms report
    a chord another app already owns by returning a value nobody reads, and on
    X11 it is worse: `XGrabKey` reports `BadAccess` *asynchronously*, so
    without an error handler plus `XSync` the call succeeds and the user gets a
    hotkey that never fires. `GlobalHotkeyUnavailability` is the shared
    vocabulary, and a Wayland session is refused up front — `XGrabKey` succeeds
    against XWayland and then under-delivers, working while an X11 app is
    focused and not otherwise, which is worse than absent because it works
    often enough to be trusted.
  - **The X11 half is a real gate.** `x11-hotkey-probe --live-check` grabs the
    chord on Xvfb, synthesizes it through XTEST, and counts the activation —
    then repeats it **with Num Lock on**, because `XGrabKey` matches modifier
    state exactly and a grab installed only under `Ctrl|Alt` silently stops
    matching the moment a lock key joins it. Then it grabs the same chord from
    a second connection and requires the refusal. All three were checked to
    fail by mutation. The Windows half has no equivalent: `RegisterHotKey` does
    not exist off Windows and nothing stands in for it, so what CI proves there
    is the numbers and the link, and "the chord fires while another app is
    focused" remains a person at a desk (`winhotkey-probe --hold`).
  - **The chord is held only while there is a microphone to mute.** A global
    registration is exclusive — it takes that key from every other app on the
    machine — so an idle app holding ⌃⌥M is taking it for a handler with
    nothing to do. Same rule macOS already follows for its panic-revoke key.

  Four things from it are worth carrying forward.

  - **One type per direction, not per endpoint.** A sharer's voice and a
    viewer's voice are the same stream in opposite directions, differing only
    in the SSRC. Writing them separately would have meant writing the mute
    latch twice, and a mute that works on one side and leaks on the other is
    the worst possible split. `SharerVoice` then pairs the two, and the SSRC
    is deliberately **not a parameter** on it: viewers key their Opus decoders
    on the sharer's reserved SSRC, so there is no correct second answer and
    therefore nothing for a host to get wrong.
  - **The capture device is opened per share, not per process.** A long-lived
    open keeps the OS microphone indicator lit while the app is idle, which
    reads to a person as "this app is listening" — so a share start opens it
    and every teardown path releases it, including the one where capture died
    on its own.
  - **A viewer's audio is withheld until the sharer assigns an SSRC.** Not
    an optimisation: an unassigned stream goes out as SSRC 0, which is the
    *sharer's* reserved voice SSRC, and the sharer's own anti-spoof gate then
    drops it. The failure mode without this is a viewer talking into a void
    with nothing logged anywhere.
  - **Both adapters report `channelCount: 1` whatever the hardware is**,
    because both recorders fold to mono themselves. Forwarding the device's
    real channel count — the obvious thing, and the number the recorders
    publish for the sharer's own information — makes the portable converter
    downmix a second time, reading N mono samples as N/2 stereo frames. That
    halves the rate and drops every voice an octave, with nothing to catch it
    but an ear.
  - **A test that races for a narrow window is not a test.** The capture
    thread's "nothing is delivered after `stop()` returns" guarantee was first
    asserted by watching for a stray delivery; that version passed every time
    against the deliberately-broken check-then-call implementation. Driving it
    from the other end — stopping *during* a slow delivery must block —
    fails against the bug every time. The same review caught a decoder-eviction
    test that asserted only the bound and would have accepted a policy that
    evicts whoever is currently talking.
- **3.2 · Sharer-side drawing surface** — unblocks *toggle drawing* and
  completes 1.4. On Windows this cannot be `WinOverlayKit`'s window:
  `WS_EX_TRANSPARENT` is load-bearing while drawing is *off* or it swallows
  every desktop click, so local drawing needs a second, non-transparent surface.

  *Both landed.* On Linux `CGtkOverlay` gained an interactive mode: arming a
  tool swaps the empty input region for a full one. On Windows it is a **second
  window** (`ts_draw_surface`), created on arm and destroyed on disarm, because
  the annotation overlay's `WS_EX_TRANSPARENT` cannot be borrowed and restoring
  a style bit is a sequence that can go wrong where destroying a window is not.
  Both hosts run the sharer's strokes through the same portable
  `AnnotationStore` the viewers use, out via `server.broadcastAnnotation` and
  back onto the same overlay.

  The hazard is the same on both, and it is most of the work: **a fullscreen
  click-swallowing overlay is a trap.** Once armed, the hub window holding the
  "stop drawing" button is underneath it. On X11 a window manager never focuses
  an override-redirect window, so Escape only reaches the overlay because it
  takes focus itself — and `ts_gtk_overlay_set_interactive` therefore *verifies*
  the focus took and **refuses to arm** if it did not, rather than shipping a
  mode nobody can leave. `tailscreen --overlay-input-self-test` injects a real
  drag and a real Escape through XTEST and has been checked to fail on all four
  ways it breaks.

  Windows differs in three ways worth carrying forward, none of them cosmetic:

  - **The refusal is still the answer, for a different reason.** A normal
    top-level window *can* be focused by the WM — but `SetForegroundWindow` is
    advisory, silently declined for a process that is not already in the
    foreground, and reports nothing. So the surface checks
    (`GetForegroundWindow` ∧ `GetFocus`) and tears itself down rather than
    arming half way.
  - **Losing focus ends drawing.** The X11 overlay cannot lose focus to a
    window manager that never gave it any; this one loses it to Alt-Tab, the
    Windows key or a UAC prompt, leaving a window that still eats the mouse and
    an Escape key going somewhere else. `WM_KILLFOCUS` is therefore wired to the
    same release path as Escape.
  - **It covers the shared region, not the desktop** — so a second monitor,
    hub window and all, stays completely usable. That is a better answer than
    the X11 sharer can give, since that one captures the whole root window.

  What is *not* verified on Windows is everything needing a real desktop: no
  window has been created, focused, refused or drawn on. The decisions were
  extracted instead — `SharerDrawingLatch`, `SharerDrawingSurfacePlan` and
  `ScreenRegion.normalizedPoint`, all in TailscreenProtocol, all covered on
  Linux CI, all adopted by the Linux host too so the two cannot drift. That is
  deliberately not the same claim as a gate; see the `linux-portal` note under
  3.3 for why overstating one is worse than not having it.

- **3.3 · Linux ScreenCast portal** — the highest-leverage *Linux* item, because
  it unblocks three rows at once: share a single window, share an app, and
  **Wayland capture at all**. Today the sharer gates on `$DISPLAY` and sees only
  the XWayland root, so native Wayland windows never reach viewers.

  *First increment landed: `Packages/PortalCaptureKit` — the D-Bus handshake
  (CreateSession → SelectSources → Start → OpenPipeWireRemote), the PipeWire
  stream, a Swift wrapper and `portal-probe`. **No row moves yet**: it is not
  wired into `Apps/linux`, there is no `CaptureEncoding` conformance, and no
  frame has been captured through it. Three things from it are worth carrying
  forward.*

  - **The consent dialog is not an obstacle to be engineered around, and it is
    also why no CI leg here can ever gate capture.** The `linux-portal` leg is
    named a *compile, link and D-Bus-protocol* gate for that reason. It is a
    real gate — deliberately breaking the Request-path derivation makes it fail
    — but it proves nothing about a real portal, PipeWire, or a pixel, and the
    workflow comment and the package README both say so at length. This repo has
    shipped gates that could not fail; a gate that overstates itself is the same
    bug wearing a green check.
  - **A declined request must not be an error.** `Failure.cancelled` is its own
    case and has its own gate. Folding it into a generic failure would put an
    error dialog in front of somebody who did exactly what they meant to.
  - **Colour was closed by subtraction.** The package converts nothing: it hands
    back BGRA and the portable `BGRAToI420` converts, exactly as
    `WGCCaptureKit` → `TailscreenSharerWGC` does on Windows. There are already
    two implementations of that arithmetic plus the viewer's shader inverting
    it, all of which must agree or every frame is washed out with no error
    anywhere; a third was the thing to avoid, not a thing to write.

  *Second increment landed: the PipeWire half is verified.* A local `pipewire`
  daemon plus a synthetic producer the package owns (`CPipeWireFakeSource`) now
  puts real pixels through `portal_stream.c` in CI — geometry, a **padded**
  `chunk->stride`, BGRA channel order, malformed-buffer rejection, and the
  end-of-source signal. Three things worth carrying forward from it:

  - **Running it found a bug that no amount of care would have.** "The source
    stopped" is not a stream state: destroying the producer drops the consumer
    to *paused*, which is what a renegotiation also looks like, so the shipped
    `UNCONNECTED → ended` mapping would never have fired. A sharer would have
    sat on a dead session showing viewers a frozen screen. It is a registry
    event now, and the gate fails without it.
  - **Every check was watched to fail** — six mutations, each with its output
    recorded in the package README's table.
  - **One trap still has no gate, and the README says so.** Producing a DMA-BUF
    needs a GPU, so deleting the `SPA_PARAM_BUFFERS_dataType` constraint leaves
    every check green. That was verified, not assumed, which is the difference
    between an honest gap and an unnoticed one.

  *Third increment landed: the `CaptureEncoding` conformance exists.*
  `Packages/TailscreenSharerPortal` is the Wayland-capable sibling of
  `X11CaptureEncoder` — PipeWire frames → the portable `BGRAToI420` →
  libavcodec. Its own package, not a target inside TailscreenLinuxBackends, so
  a viewer-only run and the `linux-viewer` gate do not acquire libdbus and
  libpipewire. Four things worth carrying forward:

  - **It is constructed with an already-negotiated session**, the same shape
    the Windows backend takes an already-picked capture item — and for a
    sharper reason. Negotiating raises a consent dialog, so a backend that
    renegotiated on restart would answer a dropped PipeWire connection by
    prompting somebody who is already mid-share. Holding the session is what
    makes the server's existing restart budget safe to use here.
  - **A resized window rebuilds the encoder rather than ending the share.**
    The portal is the only backend that can share a single window, so a
    mid-stream geometry change is ordinary rather than exceptional. The server
    already supports it: parameter sets are documented as "once per encoder
    configuration" and the anchor handler re-anchors only when its inputs
    genuinely changed. The debounce is timed from the last REBUILD, not the
    last mismatch — timing it from the mismatch would restart the clock on
    every dropped frame and leave a continuously dragged window frozen after
    the user let go.
  - **The decisions were extracted because this backend can never be gated.**
    `PortalCapturePlan` (portable tier) and `FrameHandoff` (the
    PipeWire-thread → encode-thread double buffer) carry every branch that
    could be *wrong* rather than merely unexercised, and both are tested on
    Linux CI. Same reasoning as `SharerDrawingLatch`, and deliberately not the
    same claim as a gate.
  - **A test that could not fail was found and replaced.** The torn-frame
    check was originally a stress loop; against a deliberately broken
    `publish` it scored zero hits in 3000 iterations. It is now deterministic —
    the conversion is halted mid-write and `publish` is called at that instant
    — and it does fail against that mutation.

  *Fourth increment landed: backend selection, and with it Wayland capture.*
  `CaptureBackendSelection` (portable tier) answers "which backend" from the
  session kind, `$DISPLAY` and a no-dialog portal probe; the Linux hub asks it
  at share time and negotiates consent off the main thread when the answer is
  the portal.

  - **It fixed a silent bug rather than only adding a feature.** `$DISPLAY` is
    set on Wayland by XWayland, so this app's only gate — a non-empty
    `$DISPLAY` — passed there and X11 root capture sent viewers the XWayland
    root, which on a modern desktop is usually blank. The UI said "Sharing".
    Its own "Wayland is not supported" message was unreachable for exactly the
    same reason. Session kind now comes from `XDG_SESSION_TYPE` falling back to
    `WAYLAND_DISPLAY`, and never from `DISPLAY`.
  - **A Wayland session with no portal refuses.** It does NOT fall back to the
    X11 capture that would appear to work.
  - **An X11 screen share keeps X11.** Selection is not "Wayland → portal", but
    neither is it "portal always": the portal would add a consent dialog to
    every share for a capability nobody asked for. It is reachable there for
    window and app shares, which is what it is uniquely for.
  - **Declining is not an error.** A person dismissing the consent dialog
    returns the hub to idle saying nothing, rather than showing a failure
    placard that argues with a deliberate choice.
  - **The wiring is gated separately from the decision.**
    `tailscreen --capture-backend-report` prints the choice for the current
    environment; the `linux-app` leg asserts it in three configurations. The
    `WAYLAND_DISPLAY`-with-no-session-type case is the load-bearing one — the
    explicit case returns on the first branch and cannot catch a
    detection-ORDER regression — and it was checked to fail against one.

  *Fifth increment landed, and it completes 3.3: the window/app affordance.*
  `ShareCard.secondaryStart` is a capability-shaped optional — the same shape
  the microphone and drawing slots use — that Linux fills with "Share a window
  or app…" when a portal exists and Windows leaves nil, because the WGC picker
  it already opens offers windows beside displays.

  - **There is no window list in this app, deliberately.** The portal draws its
    own picker. The compositor is the thing that knows which windows exist and
    which ones this person may see; a list built here would duplicate that and
    be less trustworthy doing it.
  - **Absent, not disabled, with no portal.** Sharing one window is a
    capability an X11-only desktop genuinely lacks, and a greyed button invites
    the question "why" with no way to answer it.
  - **The two entry points request different source types.** "Share my screen"
    asks the portal for `.monitor`; the secondary asks for `.window`, because
    portals render requested types as tabs and offering Screen back would be
    the app second-guessing a choice already made on the card.

  ⚠️ **Nothing in the portal path has been run by a person.** Five increments —
  the PipeWire verification, the encoder, backend selection, and now the
  affordance — and every one ends at a consent dialog CI cannot click. The unit
  coverage is real and the decisions are all pinned, but the first genuine
  Wayland share will be the first end-to-end run of
  `negotiate` → `openPipeWireFileDescriptor` → `PortalStream` → encoder. That
  is the single highest-value thing anyone with a Wayland machine can do next,
  and it is worth more than the next increment of code.

  *Still unbuilt: system audio (the portal has no equivalent) and multi-stream
  shares. Preview thumbnails landed in 3.4.*
- **3.4 · Change source mid-share, preview thumbnail** — ✅ **Done**, in three
  increments: the Linux half of change-source, the Windows half, and the
  thumbnail.

  **Change source, Linux.** `TailscaleScreenShareServer.changeSource` now takes
  an optional replacement capture factory, because **not every backend can be
  retargeted by `filterData` alone.** The macOS helper resolves the selection
  out of that data in its own process, so swapping the bytes is enough there.
  The Windows and portal backends are built against an already-picked target —
  a `WGC.CaptureItem`, a PipeWire node — precisely so a crash-restart
  re-targets the same thing without asking the user again. Right for a restart,
  useless for a deliberate change. The Linux hub offers "Change source…" only
  for a portal-backed share (an X11 session captures exactly one thing), the
  new dialog offers monitors AND windows because this is the moment the person
  is explicitly re-choosing, and declining keeps the existing share running
  untouched — they refused a change, not the share.

  **Change source, Windows.** This carried a hazard the Linux path does not,
  and answering it — rather than shipping the wiring — is most of what the
  Windows half is. `WindowsInputInjector` was constructed with
  `regionProvider: { resolved }`, closing over a FIXED rect, while
  `ScreenShareCaps.remoteControl` / `.annotations` are decided once when the
  server is built and advertised per viewer at HELLO time. So a naive change
  would have left a granted viewer's clicks landing on the OLD target's
  rectangle, and display→window — the ordinary case — drops the resolvable
  region entirely.

  Two things answer it, and the second is the one that matters:

  - The provider now re-reads a `liveRegion` the session updates, so events map
    to the new target, and a target with no geometry yields nil — which makes
    the injector DROP events rather than place them on the previous window.
    That is the safe half and it is **not sufficient**: a viewer holding a
    grant would go on clicking into silence.
  - So a live grant is **revoked with a reason the viewer reads**. The caps bit
    stays advertised, because it is a static "this platform can inject" and the
    protocol cannot withdraw it from viewers already admitted — but that is
    exactly the distinction the runtime gate already draws, since the "Allow
    control requests" toggle declines live requests the same way while the bit
    stays set. The sharer's own pen goes too, for the same reason: no rectangle
    to normalize against.

  The annotation overlay is rebuilt rather than moved — it owns a window on its
  own pump thread, sized at creation, and dropping it is how that thread is
  joined.

  **Preview thumbnail.** The sharer's own "this is what they can see", once a
  second, under the status line on both hubs. The starting assumption — fire
  the existing `onPreviewImage` seam — turned out to be wrong, and skipping it
  is most of what makes this small. That seam carries *encoded* bytes because
  the macOS helper is a separate process and has ImageIO on the far side of an
  IPC boundary; these three backends are in-process and have neither, so
  honouring it would mean adding an MJPEG encoder purely to decode it again one
  view later. They publish raw pixels instead, through an `onPreviewThumbnail`
  on each concrete backend attached inside the host's capture factory — the
  shape `onTimings` already uses on Windows, which also means a backend
  restarted by the server's restart budget keeps publishing.

  The scaling is `ThumbnailScaler` in the portable tier: box-average (a
  point-sampled 4 K desktop turns text into noise that reads as a broken image;
  averaging turns it into grey, which reads as small text), padded-stride
  aware, BGRA→RGBA because SwiftCrossUI's in-memory `Image` takes packed RGBA,
  and never enlarging. Every one of those is a silent failure if wrong — a
  channel swap reads as a colour-management problem, not a bug — so all four
  are mutation-tested.

  Two backends hand it the BGRA they were already given. X11 cannot: its
  capture shim converts to I420 inside `grab` and the BGRA is gone, so that one
  path converts back through `I420Converter`, which is why that type moved down
  from `TailscreenViewer` to `TailscreenProtocol` — the viewer's CPU blit is no
  longer its only caller.

  It is also the answer to a real gap the status line cannot close: "Sharing to
  2" reads identically whether the intended window is on the wire or the wrong
  one is, and after a mid-share source change that is not hypothetical. The
  preview is cleared on every teardown path, because a still picture of a
  screen that is no longer going anywhere looks exactly like a live one.

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
