# Test plan — sharer surfaces (macOS)

> **Status:** manual QA checklist for shipped features (notification
> delivery, viewer roster, hotkeys, capture outline, #174–#179). Everything
> here is **local-only** — none of it runs in CI (needs real TCC, a bundled
> app, a screen, and often a second machine) — so re-run it by hand before a
> release that touches these areas.

## Two traps before you start

1. **`make run` posts no notifications.** `SharerNoticeCenter` hard-guards
   on `Bundle.main.bundleIdentifier != nil` because
   `UNUserNotificationCenter.current()` raises on an unbundled binary.
   Use a bundled build (`build:notarized` PR label, or `make release`).
2. **`./test-local.sh` sets `TAILSCREEN_OPEN_DOOR=1`** (approval gate off),
   so the "viewer wants to connect" notification path never runs. Use
   `TAILSCREEN_OPEN_DOOR=0 ./test-local.sh 2` for anything approval-related.
   A second physical Mac beats `test-local.sh` here — notification
   behavior depends on which app is frontmost.

## A · Notification delivery

- Permission prompt on first post; **Deny** shows the "Notifications are
  turned off" notice in both the popover and the hub's sharing card, with
  a working "Open Settings"; `.notDetermined` shows nothing.
- Foreground delivery works (used to show nothing when frontmost).
- **Focus/DND split:** "wants to connect"/"wants control" break through
  (Time Sensitive); "asks you to share"/"connected/disconnected" are
  suppressed.
- **Sound leak:** with system audio + a listening viewer, connect/request
  notifications make no sound for them (`excludesCurrentProcessAudio` only
  mutes our own audio); an idle-machine request-to-share still dings.
- "Viewer left" fires per-departure, **except** Stop Sharing (no banner
  storm) and a denied pending viewer (never announced, so no departure
  banner).
- **Banner actions:** Accept/Deny, Grant/Deny, Share/Decline act like their
  in-app equivalents; Grant while locked prompts to unlock, Deny doesn't;
  **Swedish locale** — buttons read *Acceptera*/*Neka* and still work
  (why the action key and display label are separate); tapping the body
  opens the hub without deciding; swiping away leaves it pending.
- **Stale banners:** dismissed by answering in-app or by Stop Sharing;
  Accept on a banner for a viewer who already left does nothing (log: "no
  longer at the gate") — must not admit whoever now holds that address;
  repeat requests replace the banner rather than stack.

## B · Viewer roster in the hub

Hub window and popover both list connected viewers with health dots (not
just a count); hub shows no empty roster block at zero. The hub's ✕
disconnects a viewer ("disconnected by sharer"); they can reconnect through
approval again — a one-time kick, not a block, and open-door mode doesn't
silently re-admit a straggler.

## C · Hotkeys

⌃⌥M (mic) and ⌃⌥. (stop remote control) show in File menu and in System
Settings → Keyboard Shortcuts; both fire globally while another app is
frontmost; ⌃⌥. is a no-op with no active grant. Viewer's shortcut sheet
(⇧⌘/) lists Remote Control's ⌃⌥..

**Known gaps, not bugs:** as a sharer with no viewer window open, Help →
Keyboard Shortcuts is greyed out (the sheet is built inside `ensureViewer()`
— lifting it out is tracked in `plans/sharer-surfaces.md`); a hotkey
registration conflict with another app is silent (logged, not shown in UI).

## D · Capture outline

**Critical:** sharing a display, the viewer must never see the red border
(`sharingType = .none` must hold; fallback is excluding the window via
`SCContentFilter`). Appears only once live, disappears on stop, never
appears on a failed start. Tracks a window across drag/resize/Space
changes and a specific display on multi-monitor; re-fits on resolution
changes. **Change Source** moves it to the new region (mode is immutable,
so it's rebuilt). Clicks pass through it, it survives full-screen apps,
and drawing still works underneath.

## E · Regressions worth a glance

Annotations both directions; remote control grant/input/revoke incl. the
panic key; all four approval decisions from both surfaces; multi-account
switching; Stop Sharing clears the recording badge with no orphaned helper.

## F · Not macOS

Windows: look for WGC's own yellow capture border (`ts_wgc.cpp` never sets
`IsBorderRequired`) — if absent, Windows needs outline work of its own.

## Not covered here

A Focus that filters an *authorized* app is invisible to us by design — no
warning shown, since we can't detect it. Notification action buttons,
`SharerNotice`, and `ShortcutCatalog` are tested on Linux CI but consumed by
no host yet. Linux and Windows post no notifications at all.
