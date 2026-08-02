# Sharer surfaces on Linux and Windows — notifications, presence, hotkeys

> Status: plan only. Nothing implemented.

## Problem & motivation

On macOS the sharing controls live outside the window: the window is the *hub*
(sign-in, accounts, the peer list), the menubar item is the *sharer tool*, and
notifications interrupt you when someone needs an answer. You start a share,
mute, draw, approve a viewer and stop — without the window ever coming forward.

Linux and Windows put everything in one window. During a share that window is
behind the thing you are sharing, and raising it is *itself visible to your
viewers*. So every mid-share action costs an interruption the people watching
can see.

The insight that shapes this plan: **these surfaces are worth building for what
happens during a share, not before it.** Starting a share happens while you are
already in the app and needs no new surface. Everything after it does.

## Decision: no tray icon

Earlier drafts of this were a tray plan. Working out what would actually go on
the tray killed it. The candidate items were:

| Candidate | Verdict |
|---|---|
| Start a share | You are already in the app. A bonus at best. |
| Toggle microphone | Blocked on mic capture, which neither platform has. |
| Toggle sharer drawing | Blocked on a sharer overlay that can take a click. |
| Approve a waiting viewer | Belongs in a notification — it is an interrupt. |
| Stop the share | Real, but one item does not justify two platform shims. |
| "Am I still sharing?" | Real, and an **outline around the captured region says it better.** |

What is left is a status indicator, and a tray icon is a poor one: it is a
16×16 glyph in a corner the user is not looking at, on Linux it needs a shell
extension before stock GNOME will draw it at all, and it says nothing about
*what* is being captured. An outline drawn around the captured region answers
the same question in the place the user is already looking, and it answers the
sharper version of it — not "a share is running somewhere" but "**this** is what
they can see."

So: three surfaces, and the tray is not one of them.

| Surface | What it carries | Why this shape |
|---|---|---|
| **Notifications** | someone is waiting on you: viewer at the approval gate, control requested | interrupt-driven; a sharer cannot poll for these |
| **Capture outline** | what is being captured, and that it still is | ambient, always in view, needs no interaction |
| **Global hotkey** | reflex actions: mute, panic-revoke control | fastest possible, no pointer travel |

**Notifications matter most.** The one case where a sharer genuinely cannot
afford to miss something is a viewer sitting blocked at the approval gate —
"require approval" defaults **on**, so an unattended sharer silently strands
whoever tries to connect. If only one of the three ever gets built, it is this.

This decision does not touch the macOS `MenuBarExtra`, which exists, works, and
carries items (mic, drawing) that Linux and Windows cannot offer yet. Whether
macOS should also converge on notifications + outline and retire its menubar
item is a separate product question; it should not be decided as a side effect
of this plan. What *is* worth noting: if the answer there is eventually yes, then
building a tray here would be building the thing we are removing elsewhere.

## Current state

**macOS — the reference.** `TailscreenApp.swift:62` declares the hub `Window`,
`:79` the `MenuBarExtra`; both share one `AppState`. Pending viewers and control
requests render in the menubar too (`MenuBarView.swift:396`, `:404`), so a prompt
is never stranded on a surface you are not looking at. Global hotkeys exist for
the mic toggle and the revoke-control panic key (`AppState.swift:722`, `:141`).

**Notifications exist on macOS and are weaker than they look.** See the delivery
section below — this is where the surprise was.

**Nothing on Linux or Windows.** Neither app posts a notification of any kind;
`rg -i notif` over both `Sources` trees returns one unrelated GLib comment.

**swift-cross-ui provides none of this.** Checked at the pinned revision
`199a8561`: every backend implements `setApplicationMenu` — the *application menu
bar*, not a status item — and there is no `StatusItem` / `TrayIcon` / `NotifyIcon`
anywhere. swift-winui has none either; it projects WinRT, and tray icons are
Win32. (Moot now that the tray is out of scope, but worth recording so the
question is not re-opened.)

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

**Sequencing follows: notifications → outline → hotkeys → microphone capture →
sharer drawing.** The surfaces are cheap; two of their contents are not.

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

#### macOS: fix delivery before adding actions

The existing posts — `ViewerApproval.swift:63` `postJoined`, `:78` `postPending`,
`:93` `postControlRequested`, and `TailscreenUserNotifications.swift:43`
`postRequestToShareNotification` — set a title, a body and `.default` sound and
nothing else. There are four separate ways they are swallowed today, and the
first one is specifically about sharing:

1. **Focus / Do Not Disturb, including the screen-sharing case.** macOS has an
   "allow notifications when mirroring or sharing the display" setting that is
   off by default, plus whatever Focus the user is running. Every one of our
   posts defaults to `interruptionLevel = .active` and loses to all of it. The
   fix is one line per site — `content.interruptionLevel = .timeSensitive` —
   which breaks through Focus and DND, needs **no** entitlement (`.critical` is
   the one requiring Apple's approval), and is the honest level for a viewer
   blocked at an approval gate: needs attention now, useless later.
   *Unverified:* whether a third-party ScreenCaptureKit capture even counts as
   "sharing the display" for that setting. The prior from Zoom-style shares says
   it does not, and the suppression people actually hit is Focus. `.timeSensitive`
   covers both, so it is not worth distinguishing them first.
2. **Foreground suppression, and we are exposed.** No `UNUserNotificationCenterDelegate`
   is set anywhere in the mac target. Without `willPresent` returning
   `[.banner, .list, .sound]`, a notification posted while Tailscreen is frontmost
   displays nothing at all. Rare during a share — you are in another app — but it
   fires exactly when the user just clicked the menubar item. The delegate is
   needed regardless: `didReceive response:` on the same protocol is how an
   actionable notification reports its button press.
3. **Unbundled builds get nothing.** `ViewerApproval.swift:59` and
   `TailscreenUserNotifications.swift:32` both hard-guard on
   `Bundle.main.bundleIdentifier != nil`, because `UNUserNotificationCenter.current()`
   raises rather than degrading. None of this is testable with `make run` — it
   needs the bundled app, which is what the `build:notarized` PR label produces.
4. **A denied authorization is permanent and silent.** Both types request lazily
   and never re-read; `ensureAuthorization` (`ViewerApproval.swift:108`) discards
   the result entirely. A user who dismissed the prompt once gets silence forever
   with nothing in the UI saying so. Read `getNotificationSettings` at share start
   and let the sharing card say "notifications are off — approvals appear here
   only."

Then add `UNNotificationCategory` + `UNNotificationAction` and implement
`didReceive response`. Doing this first also validates the portable decision
layer against a working implementation.

**The part that cuts the other way.** A notification that succeeds is now on the
screen being captured, and viewers see it — ours and every other app's. Two
concrete leaks, both worth closing in the same pass:

- *Visually*: Cloaked Apps already has the machinery. `AppCloak.effectiveExclusions`
  (`AppCloak.swift:112`) is `.display`-only and feeds
  `SCContentFilter(display:excludingApplications:)`, so `com.apple.notificationcenterui`
  is the natural entry. Needs verifying that Notification Center actually appears
  in `SCShareableContent.applications` — system UI windows are not guaranteed to.
- *Audibly*: `content.sound = .default` on all four sites. With system-audio
  sharing on, the helper captures the system mix and `excludesCurrentProcessAudio`
  drops only *our own* audio — a notification ding comes from another process, so
  viewers hear every notification you get. Dropping the sound on the sharer-facing
  posts is probably right regardless.

#### Windows

Reachable with no new dependency. swift-winui's WinRT projection already ships
the C headers:

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

#### Linux

`org.freedesktop.Notifications` over D-Bus, which supports actions natively: an
`actions` array in `Notify()`, an `ActionInvoked` signal back. The GTK app
already links GLib, so GDBus needs no new dependency; libnotify is the
alternative. **Degrade properly:** the daemon must advertise the `actions`
capability in `GetCapabilities` — GNOME Shell and dunst do, some minimal daemons
do not — so fall back to a plain notification plus the in-window prompt rather
than posting buttons nobody can press.

### 2. Capture outline — the recording indicator

A thin, bright, click-through border drawn around exactly the region being
captured, for the duration of the share. It replaces the tray's only defensible
job and does it better: it is where the user is already looking, and it states
the capture *boundary*, not just the fact of a capture.

Two rules make it useful rather than decorative:

- **It tracks the region, not the screen.** A window share outlines that window
  and follows it; an app share outlines the union of its windows; a display share
  outlines the display. If the tracked window vanishes to another Space, the
  outline goes with it. Getting this wrong turns it into a lie about what viewers
  can see, which is worse than no outline.
- **It is never captured itself.** It must be excluded from the capture, or every
  viewer sees a border drawn around their own view of your screen. On macOS that
  is `SCContentFilter`'s exclusion list; on Windows the overlay window needs the
  same treatment WGC gives its own border.

**Windows already has one, for free.** `GraphicsCaptureSession.IsBorderRequired`
defaults to true and `ts_wgc.cpp` never sets it (`CreateCaptureSession` at `:382`,
`StartCapture` at `:397`), so a Windows share is already drawing the system's
yellow capture border — correctly positioned, correctly excluded, maintained by
the OS. **Verify this on a real desktop before writing a single line of overlay
code**: if the system border is there, the Windows half of this surface is done,
and the only work is deciding whether to keep the system border or opt out
(which needs a restricted capability) in favour of a branded one. Keeping it is
almost certainly right.

**macOS needs no new shim either.** `SharerOverlayWindow` is already a
`.statusBar`-level, `ignoresMouseEvents = true` panel whose `Mode` is
display / window / application and which already re-derives its frame on display
reconfiguration (`:259`) and tracks a shared window live with a miss-threshold
for Mission Control transitions (`updateTrackedFrame`). That is exactly the hard
part of an outline, already written and already debugged for annotations. The
outline is a border stroke in that panel, shown for the whole share rather than
only while drawing is on.

**Linux is the only one that needs new code**, because it has no sharer overlay
at all. X11: an override-redirect window with an empty input shape (`XShape`) so
clicks pass through, either one borderless full-region window or four thin
strips. Wayland is out of scope for the same reason capture is — the sharer is
X11-only today.

Because two of the three already have the machinery, this is the cheapest of the
three surfaces despite being the most visible.

### 3. Global hotkeys

For mute in particular a hotkey beats any pointing surface outright — muting is
a reflex, and a keystroke costs no pointer travel. macOS has this already.
Windows: `RegisterHotKey`, straightforward. Linux: X11 `XGrabKey` works; Wayland
needs the GlobalShortcuts portal, so expect X11-only at first, exactly like
capture.

## Implementation steps

1. **macOS notification delivery**: interruption level, the delegate, the
   authorization read-back, and the two leak fixes (cloak Notification Center,
   drop the sound). Independently valuable — it fixes a live bug on the shipping
   platform.
2. Portable `SharerNotice` decision layer + tests, reusing the macOS dedupe rules.
3. macOS: categories + actions on top of (1).
4. Windows notification shim + wiring; settle the packaged/unpackaged story.
5. Linux notification backend (GDBus) + wiring, with capability degradation.
6. **Verify the Windows WGC border on a real desktop.** If present, Windows is
   done for surface 2.
7. Outline: macOS via `SharerOverlayWindow`, then the Linux X11 shaped window.
8. Hotkeys: mute + panic-revoke; X11-only on Linux to start.
9. *Independent tracks:* microphone capture, then sharer-side local drawing.
   Their toggles join the surfaces as they land.

Steps 1–5 fix the thing that is actually broken today: an unattended sharer
silently stranding a viewer at the approval gate — on Linux and Windows because
nothing is posted, and on macOS because what is posted loses to Focus.

## Files to change / add

```
Packages/TailscreenHubUI/Sources/…/SharerNotice.swift   new (portable, tested)
Packages/WinNotifyKit/                                  new (CWinNotify + Swift)
Apps/linux/Sources/tailscreen/Notifications.swift       new (GDBus)
Apps/linux/Sources/tailscreen/CaptureOutline.swift      new (X11 shaped window)
Apps/macOS/Sources/ViewerApproval.swift                 interruption level, sound, categories
Apps/macOS/Sources/TailscreenUserNotifications.swift    same, plus authorization read-back
Apps/macOS/Sources/AppState.swift                       UN delegate, action responses
Apps/macOS/Sources/SharerOverlayWindow.swift            border stroke for the whole share
Apps/windows/Sources/tailscreen/TailscreenWindowsApp.swift wire
Apps/linux/Sources/tailscreen/main.swift                wire
docs/platform-support.md                                flip the rows
```

No `WinTrayKit`, and no tray entry on Linux — see the decision above.

## Testing strategy

- **Portable decision layer**: unit-tested on Linux CI — what to post, dedupe,
  staleness, action → outcome. This is where the real logic is.
- **Backends**: not assertable headlessly. What *is* checkable is that a missing
  notification daemon, a daemon without `actions`, or a failed post degrade
  cleanly rather than crashing — the paths most likely to be wrong.
- **macOS delivery is a manual matrix** against the notarized build, because it
  needs real TCC, a real display and real Focus state: default Focus / DND on /
  a custom Focus filtering Tailscreen / Time Sensitive revoked for Tailscreen,
  each × sharing and not sharing, asserting both that the sharer sees it **and
  that the viewer does not**.
- **The outline** is a visual check on each platform plus one assertion that
  matters more than it looks: a viewer's decoded frame must not contain the
  border.

## Risks & pitfalls

- **A notification the viewer can see is a leak, not a feature.** Both the banner
  and its sound reach viewers today. Fix them in the same pass that makes
  delivery reliable, or we will have shipped a privacy regression as an
  improvement.
- **An outline that lags the region it describes is worse than none** — it claims
  a boundary that is not the real one. The macOS overlay's existing miss-threshold
  logic exists because this is genuinely fiddly.
- **Notification actions are not universal on Linux.** Check `GetCapabilities`
  and degrade.
- **Windows unpackaged notifications need registration.** The zip build either
  registers properly or knowingly ships without toasts.
- **Win32 windows belong to their creating thread.** Post to it, as
  `WinOverlayKit` does; calling across from a Swift executor thread appears to
  work and then blocks five seconds per call.
- **Don't fork the dedupe rules.** macOS has them, with tests. Two
  implementations will disagree, and only for people who use two platforms.

## Estimated scope

| | |
|---|---|
| macOS notification delivery fixes | small — and fixes a live bug |
| Portable decision layer + tests | small |
| macOS notification actions | small |
| Windows notification shim | medium — headers exist; packaging fork to settle |
| Linux notification backend | medium — GDBus plus capability degradation |
| Outline: Windows | none if the WGC border is confirmed |
| Outline: macOS | small — `SharerOverlayWindow` already tracks the region |
| Outline: Linux | medium — the one piece with no existing machinery |
| Hotkeys (both platforms) | small–medium; Wayland is the caveat |
| **Microphone capture** | **large** — gates the mute toggle |
| **Sharer-side drawing** | **large** — gates the draw toggle |

## What would revive the tray

Recorded so the decision can be revisited on evidence rather than instinct: if
the mute and drawing toggles both land and users ask for them somewhere other
than a hotkey, there is a real case for a status item again — that is three
items, not one, and two of them are toggles a hotkey handles poorly when you
cannot remember its state. Until then, an outline and a notification cover the
ground at a fraction of the cost.

The cheaper alternative if that day comes is a small always-on-top **sharing
control window** — the macOS SharingCard as its own window — which needs no shim
on either platform and works on every desktop, including stock GNOME where a
StatusNotifierItem needs a shell extension.
