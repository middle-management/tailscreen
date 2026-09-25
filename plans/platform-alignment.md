# Platform alignment plan

> Status: Phases 0–4 done. Phase 3.3 (Linux portal) has landed in five
> increments but is untested against a real Wayland desktop/consent dialog —
> see "Open items". Phase 5 is its own plan (`plans/sharer-surfaces.md`).
> The gap list is `docs/platform-support.md`; this is the order to close it
> in, and what not to close.

## What "aligned" means here

Not "identical" — three apps on three toolkits will never render the same,
and some differences are correct forever (see Deliberate divergence). The
bar is narrower and testable:

> **A person moving between platforms should never discover a *decision*
> they cannot make.**

Capability may differ in fidelity (software vs hardware encode, one capture
backend vs another), but anything that decides something about a **person**
— approve/deny/remember/drop a viewer, grant/revoke control — must exist on
every platform that can share at all. Same rule the macOS hub and menubar
already follow between two surfaces, extended across three apps.

## Three kinds of ❌ (don't lump them)

| Kind | Example | Cost | What it needs |
|---|---|---|---|
| **A · Wiring** | Windows viewer can't draw; Linux sharer can't inject | low | portable piece exists and is tested — only the host call is missing |
| **B · Capability** | microphone capture, sharer-side drawing surface | high | a new platform shim from scratch |
| **C · Divergence** | Wayland capture, hardware encode, HDR | n/a | a decision, written down, not a task |

Sequencing: clear A first (nearly free), then the B items that unblock the
most rows, and stop treating C as debt.

## Phase 0 · Stop advertising what we can't do — done

Correctness, not alignment: `ScreenShareCaps` bits must be derived from a
real backend/overlay, never a default. (Landed as the general audit; the
motivating bug — Linux sharer claiming `annotations` with no overlay — was
fixed via 1.4.)

## Phase 1 · Close the mirror — done

Linux and Windows were mirror images on interaction (build-order accident:
Linux grew the viewer half first, Windows the sharer half). All five rows
(draw/zoom-pan/request-control as viewer, render annotations/inject control
as sharer) are now ✅ on all three platforms — almost pure kind-A wiring
onto already-portable, already-tested pieces (`AnnotationToolbar`,
`RemoteControlBar`, `ViewerZoomMath`, `WindowsKeyCodeMapping`,
`AnnotationRasterizer`, `ViewerPointerMapping`).

Decisions worth remembering (re-proposing the alternative would regress):
- **Annotations share the video's transform** (not a second surface/second
  transform) — on Windows this is now a separate RGBA overlay texture
  `CWinVideo`'s shader composites in the same pass, so strokes zoom/letterbox
  with the video for free.
- **Drawing wins over controlling** — one property (`forwardsInput`), not
  scattered per-handler, since a drag can't be both a stroke and a click.
- **Ctrl+wheel zooms, plain wheel scrolls the sharer** while a grant is held,
  on both GTK and WinUI viewers (`ViewerInputMapping.scrollDisposition`) —
  without the split one of the two is unreachable.
- **Linux annotation overlay refuses to arm on an uncomposited X11 session**
  (no alpha → opaque black rectangle instead of an overlay); withholds
  `rendersAnnotations` instead. Verified live by `tailscreen
  --overlay-self-test` (draws a stroke, reads it back via the sharer's own
  X11 capture, asserts chroma).
- **X11 injection uses keysyms, not keycodes** (`X11KeyCodeMapping`, HID→keysym,
  portable/tested; only the final `XKeysymToKeycode` needs a display).
  Scrolling is synthesized button 4/5/6/7 presses (clamped repeat count) since
  X11 core has no wheel value. Nothing injects without an explicit flush
  (`xtest-probe --live-check` covers this against real Xvfb).
- **A capability bit proves the backend exists, not that the host acts on
  it.** 1.5 shipped a correct injector/gate/bit but nothing in `Apps/linux`
  subscribed to `onControlRequestsChanged` — Linux viewers could request
  control and the sharer was never told. Fixed by joining the same
  `HubPrompt` list as viewer approvals. Generalize: a bit-derives-from-backend
  test isn't enough; also test that something *consumes* what the bit invites.

## Phase 2 · Access control — done

The most serious gap by this plan's bar (Linux/Windows could admit a viewer
and never change their mind). All four items landed:

- **2.1 Portable access-policy store** — types + `ViewerAccessPolicyStore`
  live in `TailscreenProtocol/ViewerAccessPolicy.swift`; macOS keeps its
  `UserDefaults` backing, Linux/Windows share `PeerAccessStore` (JSON file,
  injected directory, `PeerAccessStoreTests`).
- **2.2/2.3 Remembered allow / Deny & Block / kick a connected viewer** — one
  roster surface: `ViewerRosterDecision` (portable, including the queue for a
  decision made before StableNodeID resolves), `SharerAccessCoordinator`
  (remember/forget/drain, reaches the server through an injectable closure),
  `HubViewerRow`/`HubViewerRowView` (one component, both hosts). Two rules
  worth keeping: a decision made before identity resolves is **queued, not
  dropped**; the queue is **pruned when a row leaves** so a stale Deny & Block
  can't land on a different machine behind the same NAT.
- **2.4 Ask a peer to share** — the wire pair was already portable; the bug
  was that neither host kept a control listener alive while idle, so an ask
  arriving while a machine wasn't sharing got no answer at all (indistinguishable
  from "peer away"). Both apps now own a long-lived listener and hand it to
  the share. `ShareRequestInbox` (coalescing + cap) dedupes on the requester's
  **source IP**, never the self-reported hostname (a peer could otherwise fake
  many rows to pin many connections — `ShareRequestInboxTests` pins this).
  Accepting an ask **pre-approves the asker's IP**; the ask affordance is
  offered only to a peer that isn't already sharing.

## Phase 3 · Capability gates

Kind B, sequenced by rows unblocked.

**3.1 Microphone capture — done.** Unblocked speak / mute-from-outside-window
/ mute-hotkey on Linux+Windows using the already-tested Opus/framing/jitter
pipeline; only capture + hookup were missing (ALSA/PulseAudio, WASAPI).
Both mute controls now share one hotkey path (`MuteHotkeyRouting`,
`X11HotkeyKit`/`WinHotkeyKit`). Decisions worth keeping:
- **One chord; the sharer's mic wins when both are live** — the two mute
  latches are independent on purpose (both apps can share and watch at once),
  and a toggle over disagreeing latches has no sound meaning. Sharer wins
  because while sharing you're necessarily in some other app (mic control is
  behind what you're demonstrating); while only watching, the video window
  *is* what you're looking at.
- **A refused global-hotkey grab must not read as a success** — `XGrabKey`
  fails *asynchronously* (`BadAccess`), so no error handler + `XSync` means a
  hotkey that silently never fires; a Wayland session is refused up front
  rather than grabbing against XWayland and under-delivering.
- **One RTP type per direction, not per endpoint** (`SharerVoice`); SSRC is
  not a parameter — viewers key their Opus decoder on the sharer's reserved
  SSRC, so there's no second correct answer.
- **A viewer's audio is withheld until the sharer assigns an SSRC** — an
  unassigned stream would go out as SSRC 0 (the sharer's own reserved SSRC)
  and get silently dropped by the anti-spoof gate.
- **Both recorders report `channelCount: 1`** because they fold to mono
  themselves; forwarding the real hardware channel count would make the
  portable converter downmix a second time (halves the rate, drops audio an
  octave, nothing catches it but an ear).

**3.2 Sharer-side drawing surface — done.** On Linux, `CGtkOverlay` gains an
interactive mode (swap empty↔full input region on arm/disarm). On Windows,
drawing needs a **second window** (`ts_draw_surface`) since the annotation
overlay's `WS_EX_TRANSPARENT` can't be borrowed for it. Shared hazard: a
fullscreen click-swallowing overlay can trap the user with no way to reach
"stop drawing" — `ts_gtk_overlay_set_interactive` verifies its own focus took
and *refuses to arm* otherwise (`tailscreen --overlay-input-self-test` proves
it against 4 known failure modes). Windows differs: `SetForegroundWindow` is
advisory and silently declined, so the surface checks
`GetForegroundWindow`/`GetFocus` instead; `WM_KILLFOCUS` (Alt-Tab, Win key,
UAC) ends drawing the same way Escape does; it covers only the shared region,
not the whole desktop. Decisions (`SharerDrawingLatch`,
`SharerDrawingSurfacePlan`, `ScreenRegion.normalizedPoint`) live in
`TailscreenProtocol`, tested on Linux CI; Windows behavior involving a real
window/focus is **not** gated, by design (see 3.3's `linux-portal` note on
not overstating a gate).

**3.3 Linux ScreenCast portal — landed in 5 increments; unblocks Wayland
capture, single-window share, single-app share.** `Packages/PortalCaptureKit`
(D-Bus handshake, PipeWire stream) → verified against a synthetic PipeWire
producer in CI → `Packages/TailscreenSharerPortal` (own package, so
viewer-only builds don't need libdbus/libpipewire) → `CaptureBackendSelection`
(portable: picks portal vs X11 from `XDG_SESSION_TYPE`/`WAYLAND_DISPLAY`,
never `$DISPLAY` — which XWayland sets even under Wayland and was silently
sending viewers a blank XWayland root) → `ShareCard.secondaryStart` window/app
affordance (portal draws its own picker; app builds no window list itself).
Notable decisions: declining the consent dialog is `Failure.cancelled`, not
an error; colour conversion is the one shared `BGRAToI420` (no new
implementation); a resized/moved shared window rebuilds the encoder rather
than ending the share (debounced from last rebuild, not last mismatch, so a
dragged window doesn't restart its own debounce clock). System audio and
multi-stream shares remain unbuilt (the portal has no equivalent of the
former). Preview thumbnails shipped separately, in 3.4.

⚠️ **Open: nothing in the portal path has been run by a person.** Every
increment ends at a consent dialog CI cannot click; unit coverage and the
extracted decisions (`PortalCapturePlan`, `FrameHandoff`) are real but the
first genuine Wayland share will be the first end-to-end run of
`negotiate → openPipeWireFileDescriptor → PortalStream → encoder`. Highest-value
next step for anyone with a Wayland machine. Relatedly: `linux-portal` CI is
deliberately only a compile/link/D-Bus-protocol gate, not proof of a working
capture — see the package README and the workflow comment.

**3.4 Change source mid-share, preview thumbnail — done.**
`TailscaleScreenShareServer.changeSource` takes an optional replacement
capture factory because Windows/portal backends are built against an
already-picked target (`WGC.CaptureItem`, PipeWire node) — right for a
crash-restart, useless for a deliberate change, hence the extra factory hook.
Windows change-source also has to move a *live* injector target: the
provider re-reads a `liveRegion`; a target with no geometry makes the
injector drop events rather than place them on the old target, and any live
control grant is explicitly revoked (with a reason the viewer reads) since
the protocol can't silently withdraw the `remoteControl` capability bit from
an already-admitted viewer. Preview thumbnail publishes **raw pixels**
(`onPreviewThumbnail`), not the macOS helper's *encoded* IPC bytes, since
these three backends are in-process and have no ImageIO — encoding purely to
decode again would be pointless. Scaling is `ThumbnailScaler`
(TailscreenProtocol): box-average, not point-sample (avoids 4K text turning
into visual noise), padded-stride aware, BGRA→RGBA, never enlarges; all four
properties are mutation-tested since a wrong one reads as a colour bug, not a
crash.

## Phase 4 · Hub parity — done

Cheap by construction: Linux and Windows share `TailscreenHubUI`, so each
item is one change for two platforms.

- **4.1 Peer detail (route/latency/ACL tags)** — all three inputs already
  existed and were being discarded; `PeerRoute`/`ConnectionQualityTier` moved
  from `Apps/macOS` into `TailscreenProtocol` (old copies deleted, not
  duplicated — a second definition would collide via `ProtocolReexports`,
  the same hazard as the `ProfileStore` case in 2.4). Latency reuses the
  *existing* metadata round trip rather than a second dial.
- **4.2 Quality settings UI** — model/clamps/presets/persistence were already
  portable; `HubQualityMenu` renders as a menu of checked `Toggle` rows, not
  a `Picker` (swift-cross-ui's `Picker` would render raw enum case names).
  Non-mac capture backends take settings at construction, so the UI says
  "Applies to your next share" rather than pretending to apply live.
- **4.3 Connection stats overlay** — `StatsHUD` already existed; only the
  Windows numbers were missing. FPS accounting moved to portable
  `FrameRateCounter` (same reasoning as `I420Converter`/`MonoPCMConverter`);
  writing its tests found a live defect (used `0` as "not started", but `0`
  is a legitimate timestamp — the GTK sink only survived it because
  `DispatchTime.now()` never returns exactly 0).

## Phase 5 · Sharer surfaces

Own plan: `plans/sharer-surfaces.md` (status table there). Notifications on
Linux/Windows, the Linux capture outline, hotkeys on both. Listed here only
because its *mute* and *draw* toggles are gated on 3.1 and 3.2 above, so the
two plans shouldn't drift.

## Deliberate divergence

| Not doing | Why |
|---|---|
| Hardware encode off macOS | VAAPI/NVENC/Media Foundation are real work for a performance win, not a capability gap. Revisit when software encode is the measured bottleneck. |
| HDR / 10-bit / wide gamut off macOS | Capability-gated, off by default even on macOS; colour rides the SPS in-band so it needs no wire change later. |
| Menubar/tray item on Linux/Windows | Decided against in `plans/sharer-surfaces.md`: notifications + capture outline cover it; stock GNOME needs a shell extension for a StatusNotifierItem. |
| Wayland *before* the portal | Not separate — 3.3 is the answer. |

(Localized strings off macOS was on this list; reversed — shipped via
`Packages/TailscreenL10n`, see `.claude/rules/localization.md`.)

## Order, and why

```
Phase 0  (days)    stop lying                     ── independent, do now
Phase 1  (weeks)   close the mirror               ── highest value / risk
Phase 2  (weeks)   access control                 ── the "decision" bar
Phase 4  (weeks)   hub parity                     ── 1 change → 2 platforms
Phase 3  (months)  capability gates               ── unblocks Phase 5 contents
Phase 5            sharer surfaces                ── own plan
```
Phases 1/2/4 parallelize (different files/hosts). Phase 3 is the long pole.

## How to know it's working

- `docs/platform-support.md` is the scoreboard — every phase updates it in
  the same commit.
- Every ❌ that closes should close a *decision* first.
- Capability bits must stay honest — a bit a host can't back is a
  regression, not a gap.
