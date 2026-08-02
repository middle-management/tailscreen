# Sharer surfaces on Linux and Windows — notifications, tray, hotkeys

> Status: plan only. Nothing implemented.

## Problem & motivation

On macOS the sharing controls live outside the window: the window is the *hub*
(sign-in, accounts, peer list), the menubar item is the *sharer tool*, and
notifications interrupt you when someone needs an answer. You start a share,
mute, draw, approve a viewer and stop — without the window ever coming forward.

Linux and Windows put everything in one window. During a share that window is
behind the thing you are sharing, and raising it is *itself visible to your
viewers*. So every mid-share action costs an interruption the people watching
can see.

The insight that shapes this plan: **these surfaces are worth building for what
happens during a share, not before it.** Starting a share happens while you are
already in the app and needs no new surface. Everything after it does.

## Three surfaces, not one

An earlier draft of this was a tray plan. That was the wrong frame — the tray is
one of three delivery mechanisms and, on Linux, the least reliable.

| Surface | What belongs on it | Why |
|---|---|---|
| **Notifications** | someone is waiting on you: viewer at the approval gate, control requested | interrupt-driven; a sharer cannot poll for these |
| **Tray / status item** | things *you* initiate mid-share: stop, status at a glance | persistent, glanceable, no keyboard |
| **Global hotkey** | reflex actions: mute, panic-revoke control | fastest possible, no pointer travel |

**Notifications matter most and are the most portable.** The one case where a
sharer genuinely cannot afford to miss something is a viewer sitting blocked at
the approval gate — "require approval" defaults **on**, so an unattended sharer
silently strands whoever tries to connect. Notifications fix that, and unlike the
tray they work on **stock GNOME**, which needs a shell extension before it will
display a StatusNotifierItem at all.

If only one of the three ever gets built, it should be notifications.

## Current state

**macOS — the reference.** `TailscreenApp.swift:62` declares the hub `Window`,
`:79` the `MenuBarExtra`; both share one `AppState`. Pending viewers and control
requests render in the menubar too (`MenuBarView.swift:396`, `:404`), so a prompt
is never stranded on a surface you are not looking at. Global hotkeys exist for
the mic toggle and the revoke-control panic key (`AppState.swift:722`, `:141`).

**Notifications exist on macOS but are passive.** `ViewerApproval.swift` posts
`postJoined` / `postPending`; `AppState.swift:2452` posts one for an incoming
request-to-share. None carry actions — there is no `UNNotificationCategory` or
`UNNotificationAction` anywhere in the tree. So even on macOS you are *told*, and
then you go to the app. **Responding from the notification is new work on all
three platforms**; macOS is merely the cheapest, because delivery and
authorization already work.

**swift-cross-ui provides none of this.** Checked at the pinned revision
`199a8561`: every backend implements `setApplicationMenu` — the *application menu
bar*, not a status item that outlives the window — and there is no
`StatusItem` / `TrayIcon` / `NotifyIcon` anywhere. swift-winui has none either;
it projects WinRT, and tray icons are Win32.

**What the surfaces would drive already exists**, which is the good news:

| | Linux | Windows |
|---|---|---|
| start / stop share | `SharerModel.startSharing()` `:108`, `stopSharing()` `:177` | `WindowsShareSession` |
| pending viewers | `pendingViewers` `:58`, `approve` `:191`, `deny` `:193` | `approveViewer` / `denyViewer` |
| share status | `phase` `:54`, `viewerIPs` `:56` | `onStatus` (`TailscreenWindowsApp.swift:370`) |

## The two prerequisites

Two of the most-wanted items are not blocked on a surface at all. They are
blocked on a capability that does not exist on either platform:

| Wanted | Needs first | State |
|---|---|---|
| Toggle **microphone** | microphone capture | mic is macOS-only. The Opus codec, framing, jitter buffer and SSRC relay are already portable and CI-tested — only capture is missing. |
| Toggle **sharer annotation** | sharer-side local drawing | `WinOverlayKit` only *renders* annotations arriving off the wire, and its window is `WS_EX_TRANSPARENT` by construction (`ts_overlay.c:82`, "this window must never take a click"), so it cannot capture the sharer's own strokes. Linux has no sharer overlay at all. |

Neither is a flag flip. `WinOverlayKit`'s window in particular cannot just drop
`WS_EX_TRANSPARENT` while drawing is on: while drawing is *off* it must stay
click-through or it swallows every click on the sharer's desktop. Local drawing
needs a second, non-transparent surface.

**Sequencing follows: notifications → tray/hotkeys for what already exists →
microphone capture → sharer drawing → their toggles.** The surfaces are cheap;
two of their contents are not.

## Design

### 1. Actionable notifications

One portable decision layer, three thin backends. *What* to say, *when*, and how
to dedupe is pure logic and belongs where Linux CI can test it. macOS already has
`AppState.controlRequestNotificationDecision` (per-IP dedupe) and
`isStaleGrantNotification` doing exactly this — reuse those rules rather than
inventing a second set.

```
enum SharerNotice { case viewerPending(label:), controlRequested(label:), viewerJoined(label:) }
enum NoticeAction { case approve, deny, dismiss }
func noticeToPost(...) -> SharerNotice?     // dedupe + staleness live here
```

**macOS** — add `UNNotificationCategory` + `UNNotificationAction` to the existing
posts and implement `didReceive response`. Cheapest of the three, and it
validates the portable layer against a working implementation. Mind the existing
`isBundled` guard: unbundled dev builds cannot use `UNUserNotificationCenter` at
all.

**Windows** — reachable with no new dependency. swift-winui's WinRT projection
already ships the C headers:

```
Microsoft.Windows.AppNotifications.h          AppNotificationManager (WinAppSDK)
Microsoft.Windows.AppNotifications.Builder.h  the fluent toast builder
Windows.UI.Notifications.h                    classic UWP toasts
```

A C++/raw-WinRT shim posts them — the same pattern as `WGCCaptureKit`. The
*callback* half is already projected at Swift level:
`Microsoft.Windows.AppLifecycle` exposes `ExtendedActivationKind.AppNotification`,
which is how a button click comes back. **A fork to settle:**
`AppNotificationManager` works unpackaged, but needs `Register()` plus a COM
activator; from the MSIX it is simpler. We ship both a zip and an MSIX, so either
both paths work or the zip knowingly ships without toasts.

**Linux** — `org.freedesktop.Notifications` over D-Bus, which supports actions
natively: an `actions` array in `Notify()`, an `ActionInvoked` signal back. The
GTK app already links GLib, so GDBus needs no new dependency; libnotify is the
alternative. **Degrade properly:** the daemon must advertise the `actions`
capability in `GetCapabilities` — GNOME Shell and dunst do, some minimal daemons
do not — so fall back to a plain notification plus the in-window prompt rather
than posting buttons nobody can press.

### 2. Tray / status item

Content is a pure projection of share state and belongs in the portable tier
beside the notification decisions, reusing the glyph precedence
`MenubarIconStateTests` already pins on macOS (pending-request badge,
control-request badge, control outranking a waiting viewer). A tray that
disagrees with the macOS menubar about what "sharing, someone waiting" looks like
is a bug that only surfaces for people who use both.

**Windows** — `Shell_NotifyIcon` + `TrackPopupMenu` in a `CWinTray` shim beside
`CWinOverlay`, whose thread / `WndProc` / `GetMessageW` skeleton
(`ts_overlay.c:242`, `:67`, `:181`) is exactly the right pattern: a Win32 window
whose thread never pumps is one Windows treats as hung. Two warts to get right —
`SetForegroundWindow` before `TrackPopupMenu` or the menu never dismisses, and
re-add on `TaskbarCreated` or an Explorer restart loses the icon permanently.

**Linux** — StatusNotifierItem, via `libayatana-appindicator3` (GObject, binds
like `CGtkVideo`) or raw SNI over D-Bus. `GtkStatusIcon` is not an option: removed
in GTK4, never worked on Wayland.

**Capability detection is mandatory, not padding.** Stock GNOME will not show the
item; if the tray is ever the only path to an action, those users lose the action.

### 3. Global hotkeys

For mute in particular a hotkey may beat the tray outright — muting is a reflex,
and a keystroke costs no pointer travel. macOS has this already. Windows:
`RegisterHotKey`, straightforward. Linux: X11 `XGrabKey` works; Wayland needs the
GlobalShortcuts portal, so expect X11-only at first, exactly like capture.

## Implementation steps

1. Portable `SharerNotice` decision layer + tests, reusing the macOS dedupe rules.
2. macOS: add actions to the existing notifications.
3. Windows notification shim + wiring; settle the packaged/unpackaged story.
4. Linux notification backend (GDBus) + wiring, with capability degradation.
5. Tray: portable model, then `CWinTray`, then SNI — each behind a capability
   check, never the only path to an action.
6. Hotkeys: mute + panic-revoke; X11-only on Linux to start.
7. *Independent tracks:* microphone capture, then sharer-side local drawing.
   Their toggles join the surfaces as they land.

Steps 1–4 fix the thing that is actually broken today: an unattended sharer
silently stranding a viewer at the approval gate.

## Files to change / add

```
Packages/TailscreenHubUI/Sources/…/SharerNotice.swift   new (portable, tested)
Packages/WinNotifyKit/                                  new (CWinNotify + Swift)
Packages/WinTrayKit/                                    new (CWinTray + Swift)
Apps/linux/Sources/tailscreen/Notifications.swift       new (GDBus)
Apps/macOS/Sources/ViewerApproval.swift                 add categories + actions
Apps/macOS/Sources/AppState.swift                       handle action responses
Apps/windows/Sources/tailscreen/TailscreenWindowsApp.swift wire
Apps/linux/Sources/tailscreen/main.swift                wire
docs/platform-support.md                                flip the rows
```

## Testing strategy

- **Portable decision layer**: unit-tested on Linux CI — what to post, dedupe,
  staleness, action → outcome. This is where the real logic is.
- **Backends**: not assertable headlessly. What *is* checkable is that a missing
  notification daemon, a daemon without `actions`, or a failed `NIM_ADD` degrade
  cleanly rather than crashing — and those are the paths most likely to be wrong.
- Everything visual stays a manual check, like the render self-tests.

## Risks & pitfalls

- **Stock GNOME shows no tray items** without a shell extension (and a logout
  under Wayland). The single biggest argument for notifications-first, and for
  never making the tray the only path.
- **Notification actions are not universal on Linux.** Check `GetCapabilities`
  and degrade.
- **Windows unpackaged notifications need registration.** The zip build either
  registers properly or knowingly ships without toasts.
- **Explorer restarts destroy tray icons** — handle `TaskbarCreated`.
- **Win32 windows belong to their creating thread.** Post to it, as
  `WinOverlayKit` does; calling across from a Swift executor thread appears to
  work and then blocks five seconds per call.
- **Don't fork the dedupe or glyph rules.** macOS has both, with tests. Two
  implementations will disagree, and only for people who use two platforms.

## Estimated scope

| | |
|---|---|
| Portable decision layer + tests | small |
| macOS notification actions | small |
| Windows notification shim | medium — headers exist; packaging fork to settle |
| Linux notification backend | medium — GDBus plus capability degradation |
| Tray (both platforms) | medium |
| Hotkeys (both platforms) | small–medium; Wayland is the caveat |
| **Microphone capture** | **large** — gates the mute toggle |
| **Sharer-side drawing** | **large** — gates the draw toggle |

## Alternative worth considering

A small always-on-top **sharing control window** — the macOS SharingCard as its
own window — needs no shim on either platform and works on every desktop,
including stock GNOME. It is not a tray, but it covers stop/status/approve at a
fraction of the cost. If the tray work is deferred, build this instead.
Notifications remain worth doing either way.
