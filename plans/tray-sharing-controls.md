# Tray sharing controls on Linux and Windows

> Status: plan only. Nothing implemented.

## Problem & motivation

On macOS the sharing controls live in the menubar, not the window. You start a
share, draw on it, mute, and stop without the Tailscreen window ever coming to
the front — the window is the *hub* (sign-in, accounts, peer list), the menubar
item is the *sharer tool*.

Linux and Windows put everything in one window. To start a share you must first
find and raise the app; to annotate you would have to keep it in front of the
thing you are sharing, which is the one place it must not be.

The goal is the macOS affordance: **start a share and annotate without showing
the main window.**

## Goals / Non-goals

**Goals**

- A persistent tray/status item on Windows and Linux, present while the app runs.
- From it, with no main window: start a share (opens the platform picker), stop
  a share, toggle the annotation overlay, and see current share state at a glance.
- Reuse the portable state that already drives the macOS menubar; no new wire
  protocol, no new server behaviour.

**Non-goals**

- Replacing the hub window. The peer list, sign-in and account switching stay
  there; the tray is the sharer tool only, exactly as on macOS.
- Making the tray the *only* path. Every action must remain reachable from the
  window, because on Linux the tray may be invisible (see Risks).
- Viewer-side controls. A viewer already has a window it is looking at.

## Current state

**macOS — the thing being copied.** `Apps/macOS/Sources/TailscreenApp.swift:62`
declares the hub `Window`, `:79` the `MenuBarExtra`. Both scenes share one
`AppState`, so the menubar renders the same published state the window does.

**swift-cross-ui gives us nothing here.** Checked at the pinned revision
`199a8561`: every backend implements `setApplicationMenu`, which is the
*application menu bar* (macOS menu bar, GTK menu bar, WinUI menu) — a menu owned
by the app, not a status item that outlives the window. There is no
`StatusItem` / `TrayIcon` / `NotifyIcon` anywhere in the tree, and swift-winui
does not have one either: it projects WinRT, and tray icons are Win32.

So this is a platform shim, the same shape as `CGtkVideo`, `WASAPIKit` and
`WinOverlayKit`.

**The share state to drive it already exists and is observable.**

| | |
|---|---|
| Linux | `SharerModel` — `phase` (`:54`), `viewerIPs` (`:56`), `pendingViewers` (`:58`), `startSharing()` (`:108`), `stopSharing()` (`:177`) |
| Windows | `WindowsShareSession` via `onStatus` (`TailscreenWindowsApp.swift:370`), `isSupported` (`:473`) |

**The Windows message-pump pattern is already written.**
`Packages/WinOverlayKit/Sources/CWinOverlay/ts_overlay.c` creates its own thread
(`:242`), registers a `WndProc` (`:67`) and runs a `GetMessageW` loop (`:181`),
precisely because a Win32 window whose thread never pumps is one Windows treats
as hung. A tray icon has the same requirement and can copy the same skeleton.

## The catch: "annotate" is a second feature

The tray is a *delivery mechanism*. Two of the three actions it should offer
exist today; the third does not.

| Tray action | Linux | Windows |
|---|---|---|
| Start / stop share | exists (`SharerModel`) | exists (`WindowsShareSession`) |
| Show share state | exists | exists |
| **Toggle annotation drawing** | **nothing** | **nothing local** |

Windows has `WinOverlayKit`, but it is strictly a *renderer of received*
annotations: `AnnotationOverlay.apply(_ op:)` takes an `AnnotationOp` off the
wire and rasterizes it. Its window is created `WS_EX_TRANSPARENT`
(`ts_overlay.c:82`) — "this window must never take a click" — so by construction
it cannot capture the sharer's own drawing. Linux has no sharer overlay at all.

**Therefore: sharer-side local drawing is a prerequisite for the annotate half
of this, and it is the larger of the two jobs.** A tray shipped without it gets
start/stop share and status, which is most of the daily value, and the annotate
item can arrive later. That split is the recommended sequencing.

## Design

### 1. A portable `SharerTrayModel`

The tray's *content* is a pure projection of share state — items, enablement,
icon variant — and that is testable on Linux CI like every other decision in
this repo. Put it in `TailscreenHubUI` (already shared by both apps) or a small
new portable type:

```
enum TrayIcon { case idle, sharing, sharingWithPending, sharingWithControl }
struct TrayItem { let id: TrayAction; let title: String; let enabled: Bool; let checked: Bool }
func trayItems(phase:viewers:pending:canShare:drawing:) -> [TrayItem]
func trayIcon(phase:pending:controlRequests:) -> TrayIcon
```

The precedent is `MenubarIconStateTests` on macOS, which pins glyph precedence
(pending-request badge, control-request badge, control outranking waiting
viewer). Reuse those rules rather than inventing a second set — a tray that
disagrees with the macOS menubar about what "sharing with someone waiting" looks
like is a bug that only shows up when someone uses both.

### 2. Windows — `Shell_NotifyIcon`

A `CWinTray` C shim beside `CWinOverlay`, same structure:

- own thread, `WndProc`, `GetMessageW` loop (copy `ts_overlay.c`'s skeleton);
- a hidden message-only window as the icon's owner;
- `Shell_NotifyIconW(NIM_ADD, …)` with `uCallbackMessage = WM_APP+1`;
- on right-click / `WM_CONTEXTMENU`: build an `HMENU`, `SetForegroundWindow`
  (the documented workaround or the menu never dismisses), `TrackPopupMenu`;
- `NIM_MODIFY` to swap the icon and tooltip as state changes;
- `NIM_DELETE` on shutdown, and re-add on `TaskbarCreated` (Explorer restart
  destroys the icon and broadcasts that message — an app that ignores it loses
  its tray icon permanently).

The Swift side is a `TrayIcon` class posting to that thread, mirroring how
`AnnotationOverlay` posts to the overlay thread. MSIX-packaged apps can use
`Shell_NotifyIcon` normally.

### 3. Linux — StatusNotifierItem

The modern spec is **StatusNotifierItem** (KDE's KStatusNotifierItem), spoken
over D-Bus. Two routes:

- **`libayatana-appindicator3`** — GObject-based, so it binds exactly like
  `CGtkVideo` does, and handles menu export via `libdbusmenu`. Adds a system
  dependency to the AppImage/tarball.
- **Speak SNI over D-Bus directly** — no new native dependency, but it means
  implementing `org.kde.StatusNotifierItem` plus a `com.canonical.dbusmenu`
  export by hand. More code, fewer packaging headaches.

Start with ayatana; it is the smaller job and the dependency is already common
on desktop systems.

`GtkStatusIcon` is **not** an option: removed in GTK4, and it never worked on
Wayland.

### 4. Capability detection and graceful degradation

The tray must be treated as an enhancement, never the only path:

- Windows: `Shell_NotifyIcon(NIM_ADD)` returning false ⇒ no tray, log once.
- Linux: no SNI host on the bus (no `org.kde.StatusNotifierWatcher` owner) ⇒ no
  tray, log once.

In both cases the window keeps every control it has today. This is not defensive
padding — see Risks.

### 5. Annotate (deferred track)

To toggle drawing from the tray, a sharer needs a local drawing surface:

- **Windows**: a *second* overlay window, non-transparent while drawing is
  active, feeding strokes into the same `AnnotationOp` path the network already
  carries; `WinOverlayKit` continues to render the merged result. The existing
  window cannot be reused by flipping `WS_EX_TRANSPARENT`, because while drawing
  is off it must stay click-through or it swallows every click on the sharer's
  desktop.
- **Linux**: no overlay exists. A GTK layer-shell surface is the usual approach
  on Wayland; on X11 an override-redirect window. This is the biggest single
  piece of work in this document and is why it is a separate track.

Both then reuse `AnnotationCanvasModel` and `AnnotationGeometry` from the
portable tier, which already define stroke state and the shared outline maths.

## Implementation steps

1. Portable `SharerTrayModel` + tests (Linux CI), reusing the macOS glyph rules.
2. `CWinTray` shim + Swift `TrayIcon`, modelled on `CWinOverlay`; `TaskbarCreated`
   re-add; capability check.
3. Wire the Windows app: tray items → `WindowsShareSession`; `onStatus` → tray.
4. `CAyatanaTray` shim + Swift wrapper; capability check.
5. Wire the Linux app: tray items → `SharerModel.startSharing()` / `stopSharing()`.
6. Document in `Apps/*/README.md` and flip the matrix rows.
7. *(Separate track)* sharer-side drawing, then add the Draw item.

Steps 1–6 deliver "start and stop a share without the window". Step 7 delivers
the rest of the stated goal.

## Files to change / add

```
Packages/TailscreenHubUI/Sources/…/SharerTrayModel.swift   new (portable, tested)
Packages/WinTrayKit/                                       new (CWinTray + Swift)
Packages/LinuxTrayKit/                                     new (CAyatanaTray + Swift)
Apps/windows/Sources/tailscreen/TailscreenWindowsApp.swift wire
Apps/linux/Sources/tailscreen/main.swift                   wire
Apps/linux/Sources/tailscreen/SharerModel.swift            expose start from tray
docs/platform-support.md                                   flip the rows
```

## Testing strategy

- **Portable model**: unit-tested on Linux CI — item sets per phase, icon
  precedence, enablement. This is where the real logic is.
- **Windows shim**: the tray cannot be asserted headlessly, but `NIM_ADD`
  succeeding on a runner is checkable, as is the app not crashing when it fails.
- **Linux shim**: CI has no SNI host, so the meaningful automated check is that
  the *absence* of one degrades cleanly rather than crashing.
- Everything visual stays a manual check, like the render self-tests.

## Risks & pitfalls

- **GNOME does not show StatusNotifierItems out of the box.** It needs the
  AppIndicator extension, and under Wayland a full logout after installing it.
  On a stock GNOME desktop the tray item is simply invisible. This is the single
  biggest argument for never making the tray the only path to an action — a
  sizeable fraction of Linux users would lose the ability to start a share.
- **Explorer restarts destroy Windows tray icons.** Handle `TaskbarCreated` or
  the icon disappears until relaunch.
- **`TrackPopupMenu` needs `SetForegroundWindow` first**, or the menu will not
  dismiss when clicked away — a well-known Win32 wart.
- **Win32 windows belong to their creating thread.** Anything touching the tray
  window must post to its thread, exactly as `WinOverlayKit` does. Doing it from
  a Swift concurrency executor thread will appear to work and then hang for five
  seconds per cross-thread call.
- **Don't fork the icon-state rules.** macOS already has them, with tests. Two
  implementations will disagree.

## Estimated scope

| | |
|---|---|
| Portable model + tests | small |
| Windows tray shim + wiring | medium — the pattern exists to copy |
| Linux tray shim + wiring | medium — plus a packaging dependency decision |
| Sharer-side drawing (both) | **large** — separate track, gates the Draw item |

The first three are the ones that deliver the everyday win.

## Alternative worth considering first

A small always-on-top **sharing control window** — the macOS SharingCard as its
own window — needs no shim on either platform and works on every desktop
including stock GNOME. It is not a tray item, but it covers the actual need
(reach stop/draw/mic while the main window is out of the way) at a fraction of
the cost, and it does not depend on the user having installed a shell extension.

If the tray work is deferred, this is the thing to build instead.
