# Test plan — sharer surfaces (macOS)

Covers what landed in #174–#179: notification delivery, the notifications-off
notice, viewer join/leave, the viewer roster in the hub, hotkey documentation,
and the capture outline.

Everything here is **local-only**. None of it can run in CI: notifications need
real TCC and a bundled app, the outline needs a screen, and the interesting
cases need a second machine.

---

## Before you start — two traps

**1. `make run` posts no notifications at all.** `ViewerJoinNotifier` and
`TailscreenUserNotifications` both hard-guard on `Bundle.main.bundleIdentifier
!= nil`, because `UNUserNotificationCenter.current()` *raises* on an unbundled
binary rather than degrading. A `swift build` product has no Info.plist.

> Use a bundled build: add the **`build:notarized`** label to a PR and take the
> artifact, or `make release` and wrap it. If you see zero notifications and no
> permission prompt, this is why — check it before debugging anything else.

**2. `./test-local.sh` sets `TAILSCREEN_OPEN_DOOR=1`,** which turns the approval
gate **off** — so viewers auto-admit and the "viewer wants to connect" path
never runs. That is the single most important notification to test.

> `TAILSCREEN_OPEN_DOOR=0 ./test-local.sh 2` for anything involving approval.

A second physical Mac is better than `test-local.sh` for these, because
notification behaviour depends on which app is frontmost.

---

## A · Notification delivery

### A1 · Permission prompt
- [ ] Fresh install, start a share, have someone connect → macOS asks for
      notification permission on the first post.

### A2 · Denied → the app says so
- [ ] **Deny** at the prompt (or System Settings → Notifications → Tailscreen →
      off). Start a share.
- [ ] The "Notifications are turned off for Tailscreen" notice appears in the
      **menubar popover**.
- [ ] …and in the **hub window's** sharing card. (Both, from one component.)
- [ ] **Open Settings** opens System Settings → Notifications, not some other
      pane.
- [ ] Re-allow, start a new share → the notice is gone.

### A3 · Not-yet-asked shows nothing
- [ ] Fresh install, share **before** any notification has fired → **no** notice.
      (Warning before asking is crying wolf; `.notDetermined` must stay silent.)

### A4 · Foreground delivery — the delegate fix
- [ ] With Tailscreen **frontmost** (popover open or hub focused), have a viewer
      connect → a banner still appears.
      Before this change, foreground posts displayed nothing at all.

### A5 · Focus / Do Not Disturb — the urgency split
Turn on a Focus (any) that does **not** explicitly allow Tailscreen.

| Notification | Expected under Focus |
|---|---|
| Viewer wants to connect | ✅ breaks through (Time Sensitive) |
| Viewer wants control | ✅ breaks through |
| Someone asks *you* to share | ❌ suppressed — idle machine, natural retry |
| Viewer connected / disconnected | ❌ suppressed — reports, not asks |

- [ ] All four rows behave as above.
- [ ] System Settings → Notifications → Tailscreen shows a **Time Sensitive**
      toggle (proof the entitlement-free level took effect).

### A6 · Sound leak — needs a viewer watching
Share a display **with system audio on**, and have a viewer listening.

- [ ] Viewer connects / asks to connect / asks for control → the **viewer hears
      no notification ding**. (`excludesCurrentProcessAudio` only drops our own
      audio; a notification sound comes from another process.)
- [ ] While **idle** (not sharing), a request-to-share still dings locally —
      that one keeps its sound because nothing is being captured.

### A7 · Viewer left
- [ ] A viewer disconnects → "stopped viewing your screen".
- [ ] **With 2+ viewers connected, press Stop Sharing → no "left" banners at
      all.** Teardown expels everyone; one banner per viewer at the moment you
      already decided to stop is the noise this is gated against.
- [ ] Deny a pending viewer → no "left" banner (their arrival was never
      announced, so their departure isn't either).

---

## B · Viewer roster in the hub

### B1 · Visible on both surfaces
- [ ] During a share, the **hub window** lists connected viewers by name with
      health dots — not just the "N viewers connected" count.
- [ ] The menubar popover still does too.
- [ ] With zero viewers, the hub shows no empty roster block.

### B2 · Dropping a viewer from the hub
- [ ] Click the ✕ on a viewer row **in the hub window** → that viewer is
      disconnected and sees "disconnected by sharer".
- [ ] The dropped viewer can **reconnect**, and goes back through the approval
      prompt. (One-time kick, not a block — nothing is remembered.)
- [ ] Their straggler reconnect does not silently re-admit in open-door mode.

---

## C · Hotkeys and their documentation

### C1 · The menu says what exists
- [ ] **File → Microphone** now shows **⌃⌥M**.
- [ ] **File → Stop Remote Control** shows **⌃⌥.** and is greyed out unless a
      viewer holds control.
- [ ] System Settings → Keyboard → Keyboard Shortcuts → App Shortcuts can see
      both by title (this is what menu items buy you).

### C2 · The shortcuts actually fire
- [ ] ⌃⌥M toggles the mic **while another app is frontmost** (global hotkey).
- [ ] ⌃⌥. revokes control while a viewer is controlling — from another app.
- [ ] ⌃⌥. does nothing when no grant is live (it's registered only during one).

### C3 · The cheat sheet
- [ ] In a **viewer** window: ⇧⌘/ (or Help → Keyboard Shortcuts) opens the
      sheet, and it now has a **Remote Control** section listing ⌃⌥..

> **Known gap, not a bug to report:** as a **sharer** with no viewer window
> open, Help → Keyboard Shortcuts is greyed out and ⌘? does nothing. The sheet
> is still built inside `ensureViewer()`. Lifting it out is the next step and is
> tracked in `plans/sharer-surfaces.md`.

### C4 · Registration conflict (optional)
- [ ] Give another app ⌃⌥M, relaunch Tailscreen → the log names
      `RegisterEventHotKey failed`. Nothing in the UI says so yet; that's queued
      with the cheat-sheet lift.

---

## D · Capture outline

### D1 · The critical one
- [ ] Share a **display** with a viewer watching. **The viewer must NOT see the
      red border.** If they do, `sharingType = .none` isn't holding and the
      fallback is to exclude the window in `SCContentFilter` — say so and stop
      here, the rest of section D doesn't matter.

### D2 · It appears and disappears
- [ ] Border appears when the share goes live (not while "Starting…").
- [ ] Disappears on Stop Sharing.
- [ ] A share that **fails to start** (e.g. deny Screen Recording) leaves no
      border behind.

### D3 · It tracks the region
- [ ] **Window share:** the border frames that window and follows it as you drag
      and resize.
- [ ] Send that window to another Space → the border goes with it, and does not
      linger over empty desktop.
- [ ] **Display share** on a multi-display Mac: the border is on the *shared*
      display only.
- [ ] Change resolution / plug a display → the border re-fits.

### D4 · Change Source
- [ ] Mid-share **Change Source…** to a different display or window → the border
      moves to the new region. (Its mode is immutable, so it is rebuilt.)

### D5 · It doesn't get in the way
- [ ] Clicks pass through the border area — it covers the whole shared region.
- [ ] It stays visible over a full-screen app.
- [ ] Drawing (Draw on Screen) still works, and viewer strokes still render.

---

## E · Regressions worth a glance

- [ ] Annotations both directions (sharer draws → viewers see; viewer draws →
      sharer sees).
- [ ] Remote control grant → input → revoke, plus the ⌃⌥. panic key.
- [ ] Approve / Deny / Always Allow / Deny & Block from **both** surfaces.
- [ ] Multi-account switching still works.
- [ ] Stop Sharing clears the menubar recording badge (no orphaned helper).

---

## F · Not macOS — one cheap check

- [ ] **Windows:** start a share and look for a **yellow border** around the
      captured window/display. `ts_wgc.cpp` never sets `IsBorderRequired`, so
      WGC's own border should already be drawn. If it is, Windows needs no
      outline work at all; if it isn't, say so and it goes on the list.

---

## What this does *not* cover

Recorded so a gap doesn't read as a failure:

- **A Focus filtering an authorized app is invisible to Tailscreen.** If
  notifications are allowed but a Focus eats them, the app shows no warning —
  by design, since it cannot know. An absent warning means "not denied", never
  "will definitely appear".
- **Notification action buttons don't exist yet** — you're told, then you go to
  the app. Approve-from-the-banner is step 3 of the plan.
- **Linux and Windows post no notifications at all.** Steps 4–5.
- **`SharerNotice` and `ShortcutCatalog` are not consumed by any host yet.**
  They're tested on Linux CI but nothing calls them; macOS adopts them when
  actions land.
- **`GlobalHotkey.isRegistered` has no reader** — see C4.
