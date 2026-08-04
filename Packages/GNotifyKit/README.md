# GNotifyKit

Desktop notifications on Linux, over `org.freedesktop.Notifications`. What
`UNUserNotificationCenter` is on macOS and `AppNotificationManager` is on
Windows.

## Why this exists

During a share, the app window is **behind the thing being shared**, and raising
it is itself visible to viewers. So every mid-share ask costs an interruption
the people watching can see.

Worse: "Require approval for new viewers" defaults **on**. A sharer who is not
looking at the app silently strands whoever tries to connect — nothing on screen
changes, and the viewer sits on a "waiting for approval" placard indefinitely.
A notification is the only surface that reaches somebody whose attention is on
the thing they are sharing.

## The split

| Where | What |
|---|---|
| `TailscreenProtocol` (`SharerNotice`) | *what* to say, *when*, how to dedupe, when to withdraw |
| this package | delivery only |

This package knows nothing about viewers, shares or control grants. That is not
tidiness — it is what lets the decisions be tested on Linux CI with no daemon,
no bus and nobody at a keyboard, and lets all three platforms share one set of
rules instead of three that drift.

## Why a C shim

Every GDBus call that carries arguments goes through `g_variant_new`, which is
**variadic** and therefore uncallable from Swift. `Notify` takes
`(susssasa{sv}i)` — eight fields, two of them containers — which needs
`GVariantBuilder` on top of the same varargs. Same argument as
PortalCaptureKit's shim, same split: C owns the wire, Swift owns everything
else.

## The three things that bite

1. **Signals arrive on the thread-default `GMainContext` captured at subscribe
   time.** A notifier constructed on a thread that never iterates a main loop
   posts perfectly and never reports a single button press. In the GTK app that
   means constructing it on the main thread. This is the failure the live gate
   exists for; nothing else catches it.
2. **A daemon that does not advertise the `actions` capability silently DROPS
   your buttons** rather than failing the call. Posting an Accept/Deny pair to
   one of those produces a banner that states a decision and offers no way to
   make it — strictly worse than a plain notification, because the user waits
   for something that is not coming. Ask `supportsActions` and say where to
   answer instead. GNOME Shell and dunst advertise it; several minimal daemons
   do not.
3. **A notice's life is tied to the thing it is about.** A banner reading
   "someone is waiting to be let in", with an Accept button, is actively wrong
   once they have been let in from the app window: pressing it then does
   nothing, or lands on whoever connects next. `withdraw` is why that method is
   part of the API rather than a detail left to expiry.

`init?` returning nil — no session bus, no daemon — is a **normal state**, not
an error to report. A headless box, a minimal session and a container all land
there. The host keeps its in-window prompts and says nothing.

## What is proven

| Claim | Proven by | Where |
|---|---|---|
| gio/glib actually LINK | running `gnotify-probe` at all | `linux-notify` |
| the `Notify` argument signature | `--live-check` against a real daemon | `linux-notify` |
| `GetCapabilities` is read, not assumed | `--live-check` asserts `actions` + `body` | `linux-notify` |
| `replaces_id` updates in place rather than stacking | `--live-check` | `linux-notify` |
| **signals reach the subscriber** | withdraw → `NotificationClosed(reason=3)` | `linux-notify` |
| **a real button press comes back** | `dunstctl action` → `ActionInvoked` | `linux-notify` |
| what any of it LOOKS like | **nothing** | — |

The last row is the honest one. dunst under Xvfb draws to a screen nobody sees,
and whether GNOME Shell renders two buttons or hides them behind a chevron is
not a question a probe can answer. Neither is whether the wording is right.

Each of the first six was verified by breaking it: the signature mutation
(`(susssasi)`), the subscription mutation (subscribe to nothing), and the
actions mutation (drop them despite the capability) each turn the gate red.

## Running the gate

```bash
swift build --package-path Packages/GNotifyKit --product gnotify-probe
Packages/GNotifyKit/.build/debug/gnotify-probe            # link check
xvfb-run -a dbus-run-session -- bash -c '
  dunst & sleep 1
  Packages/GNotifyKit/.build/debug/gnotify-probe --live-check --invoke-with "dunstctl action"'
```

`--invoke-with` is how the probe stays daemon-agnostic: it names no daemon, and
the caller supplies whatever command presses the button.

Install: apt `libglib2.0-dev`. Runtime needs a notification daemon; there is no
fallback and none is wanted — a fallback would be a second notification system
to keep working.
