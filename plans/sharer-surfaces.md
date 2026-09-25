# Sharer surfaces — notifications, presence, hotkeys, discoverability

> Status: mostly shipped. Notifications (all 3 platforms), the capture outline
> (macOS + Linux), the portable shortcut catalog, and mute hotkeys (macOS/Linux/
> Windows) are done. Open: confirm the Windows WGC border on real hardware,
> lift the shortcut cheat sheet off the viewer-only window, panic-revoke hotkey
> on Linux/Windows, and the two large tracks (mic capture, sharer-side drawing).
> See the status table below.

## Problem

On macOS, sharing controls live outside the window (hub window vs. `MenuBarExtra`
sharer tool). Linux and Windows put everything in one window, so raising it
mid-share is itself visible to viewers. Insight: these surfaces are worth
building for what happens *during* a share, not before it — starting a share
needs no new surface, everything after does.

## Decision: no tray icon

A tray icon was the original idea; working out what would go on it killed it.
Every real candidate (mute, drawing, stop) is either blocked on a missing
capability or better served elsewhere; "am I still sharing, and with what" is
answered better by an outline drawn around the captured region than by a 16×16
glyph in a corner nobody is looking at — and stock GNOME won't draw a
`StatusNotifierItem` without a shell extension anyway. So: four surfaces
instead — **notifications** (someone is waiting on you), **capture outline**
(ambient, what's being captured), **global hotkeys** (reflex actions: mute,
panic-revoke), **discoverability** (so the hotkeys are findable at all). This
does not touch the macOS `MenuBarExtra`, which stays for mic/drawing controls
Linux and Windows can't offer yet; whether macOS should eventually converge on
notifications+outline and drop the menubar item is a separate, undecided
question.

**Notifications matter most**: "require approval" defaults on, so an
unattended sharer silently strands a waiting viewer if notifications don't
work. This was true and turned out to be doubly true — macOS already had
notifications, but they lost to Focus/DND by default (`.active` instead of
`.timeSensitive`), had no delegate (so foreground posts showed nothing), and a
denied authorization was permanent and silent. All fixed; see status table.

## Key design decisions

- **Portable decision layer, platform-thin backends.** `SharerNotice` (in
  `TailscreenProtocol`, not `TailscreenHubUI` — HubUI carries SwiftCrossUI,
  which macOS doesn't build) decides *what* to post, dedupe and staleness;
  each platform only renders and wires it. This collapsed macOS's three
  separate ad-hoc dedupe mechanisms into one.
- **Urgency ≠ actionability.** Only the two mid-share asks (viewer pending,
  control requested) get `.timeSensitive` (breaks Focus/DND, no entitlement
  needed). `requestToShare` has buttons but isn't urgent — it arrives at an
  idle machine with a natural retry. Reason: every OS revokes the Focus
  exemption *per app*, not per notification, so overusing it disarms the
  kinds that actually need it.
- **viewerJoined/viewerLeft is a matched, gated pair**: only viewers whose
  arrival was announced get a departure notice, and nothing posts during
  teardown (stopping a share shouldn't fire one leave-banner per viewer).
- **Action keys are derived from `NoticeAction`, not spelled out per backend.**
  Two independent literal lists would work on day one and silently stop
  routing later.
- **Windows packaging fork resolved at runtime, not build time.** Toast
  registration (`AppNotificationManager.Register()`) either succeeds or
  doesn't; the host degrades to in-window prompts and says so on the share
  card either way — the same shape the Linux backend already has for "no
  session bus". Avoids shipping two configurations where only one gets
  tested. The zip build is expected to report "not registered" until
  `stage-winappsdk.sh` also stages the WinAppSDK Singleton package (a
  deployment change, not a code change).
- **Two viewer-visible leaks, fixed**: the sound (`.default` on all posts —
  system-audio capture picks up the ding since it's not our process audio;
  fixed by muting sound for the whole share) and the visual leak (deferred —
  excluding Notification Center from `SCContentFilter` risks also excluding
  the menu bar on modern macOS, unverified without a real desktop).
- **Menu item is the source of truth for hotkey discoverability**, not a
  hand-maintained cheat-sheet list — a menu item's key equivalent gets
  Help-menu search, VoiceOver, and System Settings remapping for free; two
  hand-drawn lists on macOS had already drifted (⌃⌥. missing from one).
- **Capture outline reuses the sharer's existing annotation overlay** rather
  than a second window, on both macOS (`SharerOverlayWindow`, already tracks
  the capture region) and Linux (already the capture rectangle, already
  click-through). Windows likely needs nothing — WGC's `IsBorderRequired`
  already draws a system border, positioned and excluded by the OS; **needs
  confirming on real hardware**.
- **Outline is gated to X11 display shares on Linux** — a portal share
  reports stream size but no position, so an outline there would be wrong
  rather than absent; wrong is worse, so it's suppressed. Border thickness is
  clamped (unclamped, a border ≥ half the smaller dimension fills the buffer).
- **Rejected: Wayland hotkeys/outline for now** — sharer capture itself is
  X11-only today, so scope matches.

## Two prerequisites blocking the biggest wants

- **Mic toggle** needs microphone *capture* (mic is macOS-only today; Opus
  codec/framing/jitter/relay are already portable and tested).
- **Sharer-side drawing** needs a real, non-transparent drawing surface.
  `WinOverlayKit`'s window is `WS_EX_TRANSPARENT` by construction and can't
  take a click without breaking click-through when drawing is off; Linux has
  no sharer overlay at all. Both are large, unstarted tracks.

## Status

| Step | State |
|---|---|
| macOS notification delivery (interruption level, UN delegate, auth read-back, sound/visual leak) | done (visual leak deferred, needs real-desktop check) |
| Portable `SharerNotice` decision layer | done — `TailscreenProtocol`, tested on Linux CI |
| macOS categories + actions on top of delivery | done — `SharerNoticeDecision.noticesToPost`/`noticesToWithdraw` wired in `AppState.swift`, `UNNotificationCategory` in `ViewerApproval.swift` |
| Windows notification shim | done — `Packages/WinNotifyKit`; packaging fork resolved at runtime; no CI observes an actual posted toast (honest gap vs. Linux) |
| Linux notification backend | done — `Packages/GNotifyKit`, gated by `linux-notify` against real dunst incl. a button press |
| Windows WGC capture border | **needs a real desktop**, not code |
| Outline: macOS | done — `CaptureOutlineWindow` |
| Outline: Linux | done — `CaptureOutline`, X11 display shares only |
| macOS discoverability + viewer roster in hub | done — ⌃⌥M key equivalent, ⌃⌥. in sheet, `ViewersList` un-privated into hub |
| Portable `ShortcutCatalog` | done — 18 tests on Linux CI, but **not yet consumed**: cheat sheet still not derived from it |
| Mute hotkeys (macOS/Linux/Windows) | done — `Packages/X11HotkeyKit`, `Packages/WinHotkeyKit`; `x11-hotkey-probe --live-check` is a real gate |
| Panic-revoke hotkey on Linux/Windows | **not started** — needs the sharer-side grant UI first |
| Mic capture, sharer-side drawing | **not started** — the two large tracks |

**Still open:** the shortcut cheat sheet (`ViewerShortcutsOverlayHost`) is
built inside `AppState.ensureViewer()` and gated on `shortcutsModel != nil`,
so Help → Keyboard Shortcuts is only reachable while *watching* someone — the
sharer, who has the global hotkeys, still can't open it. Fixing this is also
where `ShortcutCatalog` and `GlobalHotkey.isRegistered` get their first reader.

## Risks worth remembering

- A notification or its sound that reaches the *viewer* is a privacy leak, not
  a feature — both were live bugs, fixed in the same pass as delivery.
- An outline that lags the region it claims to show is worse than no outline.
- Notification actions aren't universal on Linux — check `GetCapabilities`
  and degrade to a plain notification + in-window prompt.
- A hotkey that silently failed to register (every platform's registration
  call fails this way by default) is worse than none; surface `isRegistered`.
- Don't fork the notice-dedupe rules or the shortcut list a second time —
  both have already drifted once when duplicated by hand.

## Pointers

- Decision layer: `TailscreenProtocol/SharerNotice.swift` (also holds
  `SharerNoticeText`, `noticesToWithdraw`).
- macOS wiring: `Apps/macOS/Sources/AppState.swift`, `ViewerApproval.swift`,
  `TailscreenUserNotifications.swift`.
- Windows: `Packages/WinNotifyKit`, `Apps/windows/.../TailscreenWindowsApp.swift`.
- Linux: `Packages/GNotifyKit`, `Apps/linux/Sources/tailscreen/SharerNotifications.swift`,
  `CaptureOutline.swift`.
- Hotkeys: `Packages/X11HotkeyKit`, `Packages/WinHotkeyKit`,
  `Apps/macOS/Sources/GlobalHotkey.swift`.
- Related: `docs/platform-support.md` (feature matrix), `plans/sharer-surfaces-test-plan.md`
  (test plan for this feature), `plans/platform-alignment.md` (cites the
  no-tray decision).

## Future: request to annotate (not scheduled)

Recorded so the shape isn't rediscovered from scratch. Annotation is currently
ungated — any admitted viewer can draw, fanned out to everyone. Remote
control already solved the same shape of problem (viewer-initiated request,
sharer-side grant gate keyed by `connectionID`, same notice/dedupe rules,
same auto-revoke triggers) and mostly generalizes, except: control is
single-grantee, annotation is naturally multi-grantee (a set, not a slot); and
control defaults closed while annotation should probably default open,
flipping to request-based only above some viewer count. The capability bit
already exists (`ScreenShareCaps.annotations`, bit 4) so old peers degrade
safely.

## What would revive the tray

If mic + drawing toggles both land and users ask for them somewhere other
than a hotkey, a status item becomes a real 3-item case again. Until then, an
outline + notifications cover the ground more cheaply. The cheaper fallback if
that day comes is a small always-on-top sharing-control window (macOS's
`SharingCard` as its own window) rather than a tray shim.
