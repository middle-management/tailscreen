---
title: Usage
nav_order: 4
permalink: /usage/
---

# Usage
{: .no_toc }

1. TOC
{:toc}

## First-time setup

You need a Tailscale account — the free personal tier is fine, and it
doesn't expire. Sign up at [tailscale.com](https://tailscale.com/),
install the Tailscale app on every machine you want to share between, and
let it add them to your tailnet. Then install Tailscreen on those machines
(see [Install]({% link install.md %})).

You do **not** need to register Tailscreen as a Tailscale device. It spins
up its own ephemeral tsnet node when you start sharing or connecting, and
Tailscale removes the node automatically when you stop. Your admin console
stays clean.

If you'd rather not use Tailscale's hosted control plane — you run
[headscale](https://github.com/juanfont/headscale), say, or you want a
fully airgapped tailnet — see
[Self-hosted control planes]({% link self-hosted.md %}).

## Platform notes

Tailscreen is one app on three platforms — macOS, Linux, and Windows — and
they all speak the same protocol, so any of them can view or share to any
other. This page uses the macOS app's menus and keyboard shortcuts in its
examples; the hub window, share card, and viewer work the same everywhere.
The honest differences:

- **Sharing works everywhere**, with one Linux caveat: capture goes through
  X11, so a Wayland session can view but not yet share — the app detects
  this and says so.
- **Remote control** can be requested from any viewer, but only a macOS or
  Windows sharer can grant it. The Linux sharer can't inject input yet, so
  it doesn't advertise the capability and its viewers never see a Request
  Control button.
- **Audio capture is macOS-only today.** The mic button and **Share System
  Audio** exist on the macOS app; Linux and Windows endpoints play back the
  audio they receive but don't capture any.
- **Permissions:** Screen Recording and Accessibility prompts are macOS
  concepts. Linux and Windows have no equivalent gate.

## Sharing your screen

1. Click the 📺 in the menubar, or open the Tailscreen window.
2. Pick **Choose what to share…**. The native picker opens — choose a
   display, a single window, or one or more apps.
3. On a Mac, approve Screen Recording if macOS asks. (See
   [Install → Permissions]({% link install.md %}#permissions) — the
   permission only takes effect after a relaunch.)
4. The first time you ever share, Tailscale will open a browser tab to log
   you in. After that it's a one-click affair.

That's the whole flow — no meeting to create, no link to copy. The screen
is up, people on your tailnet can connect, and by default each one waits
for your approval before they see anything (see
[Approving viewers](#approving-viewers)).

### Changing what you share mid-session

While sharing, pick **Change Source…** in the sharing card. It reopens the
picker without disconnecting anyone — viewers see a brief pause and then
the new content. Annotations are cleared on both ends when the source
changes, so stale strokes don't float over the new content.

### Cloaked Apps: hiding apps from viewers

Some apps just shouldn't be on stream — Messages, Mail, your password
manager. Add them once in **Settings → Cloaked Apps** and their windows
are excluded from every whole-display share, so there's no need to clean
up your screen before sharing. The **Add App…** menu lists
your running apps; each entry has a **Remove** button, and the **Hide
cloaked apps while sharing** toggle lets you temporarily disable cloaking
without losing the list.

The rules, spelled out:

- **Applies to display shares.** Sharing a single window or app already
  limits capture to exactly what you picked, so there's nothing to cloak.
- **An explicit pick wins.** If you deliberately choose to share a cloaked
  app (window or app share), it's shared — a standing default never
  overrides a deliberate choice.
- **It's live.** Editing the list mid-share applies within a second or
  two; viewers see a brief pause while the capture pipeline rebuilds.
  A cloaked app that *launches* mid-share is picked up the same way.
- Cloaked windows are excluded at capture time — the pixels never reach
  the encoder, never mind the network. Viewers simply see your wallpaper
  (or whatever is behind the window) where the app would be.

## Viewing a shared screen

1. Open the Tailscreen window — click its Dock icon, or pick **Open
   Tailscreen** in the menubar.
2. Find the sharer in the **Screens** list. Search by name or IP, or use
   the filter to show only screens currently being shared — a peer that's
   sharing carries a green chip with its share's name.
3. Click their row.

A window opens. You're done — unless the sharer has viewer approval on (the
default), in which case you'll sit on the Connecting screen until they
accept you.

Want a look before you connect? Expand a row with its chevron: you get the
live share's resolution and codec, the peer's MagicDNS name and IP (both
copyable), and a Route line showing the current Tailscale path — direct or
DERP-relayed — with a rough latency estimate.

## Approving viewers

**Require approval for new viewers** is on by default. When someone
connects to your share, they don't see pixels — they wait on their
Connecting screen while your menubar shows a row for them with four
choices:

- **Accept** — admit them, this once.
- **Always Allow** — admit them now and automatically in the future.
- **Deny** — reject them, this once. They see "Connection Declined".
- **Deny & Block** — reject them now and automatically in the future.
  Blocking someone who's *already* connected kicks them out too.

Once viewers are connected, each row in the sharing card's viewer list
has a ✕ button that disconnects that viewer on the spot. It's one-time —
they see "Disconnected by Sharer" and nothing is remembered, so they can
reconnect and go through the normal approval flow again. To keep someone
out for good, use **Deny & Block** instead.

You also get a notification ("Viewer Wants to Connect") if the menubar
isn't open. Remembered decisions live in **Settings → Viewers** under
"Remembered viewers", where you can remove entries any time. They're keyed
to the peer's stable Tailscale node identity, not its IP or hostname, so a
renamed machine stays remembered.

If you'd rather have the old anyone-on-the-tailnet-connects-instantly
behavior, turn the toggle off in **Settings → Viewers**. Blocked peers
stay blocked even then — the deny list outranks the toggle.

## Asking someone to share

The flow also works in reverse. Expand a peer's row in the Screens list
and click **Ask to Share** to ask that peer to share *their* screen.
Clicking it puts a banner in their Tailscreen — "*name* wants you to
share", with **Share** and **Decline** buttons. If they hit Share, the
picker opens on their machine, and you're automatically pre-approved for the
share that follows — no second approval round-trip.

You'll get one of three outcomes: **Request Accepted** ("…is choosing what
to share" — click their row once their share is up), **Request Declined**,
or **No Response** ("They may be away or running an older Tailscreen").

## Multiple accounts

Signed in to more than one tailnet — personal and a work org, say? The
account menu (the avatar in the window's header) lists every profile with
its login and tailnet name, Tailscale-style. Click one to switch; the
others stay signed in on disk, so switching back is instant and
browser-free. **Add Account…** starts a fresh sign-in, holding ⌥ over a
profile row swaps it for **Remove Account…**, and the menubar's identity
strip always shows which account a new share will start on.

## Annotations

The viewer's toolbar has drawing tools. Doodle on the sharer's screen and
your strokes appear in a transparent overlay window on their machine. The
back-channel rides over TCP rather than the lossy UDP video stream — see
[Network Protocol]({% link protocol.md %}) — so individual stroke segments
won't drop even if you lose a video frame or two.

Annotations aren't persisted on either end — quit the viewer or stop
sharing and they're gone.

## Voice chat

Both sides have a mic button on macOS (**⌃⌥M** works system-wide, even when
Tailscreen isn't focused; other platforms are playback-only for now — see
[Platform notes](#platform-notes)). Audio is Opus over the same tunnel as
the video.
With multiple viewers, everyone hears everyone — the sharer relays each
viewer's voice to the other viewers. The receive path runs an adaptive
jitter buffer with packet-loss concealment, so a lossy Wi-Fi link degrades
into brief soft spots rather than robotic stutter.

## Sharing system audio

The sharing card has a **Share System Audio** button (macOS — see
[Platform notes](#platform-notes)) — everything your Mac plays gets
captured and streamed to viewers alongside the video. **Mute
System Audio** toggles it back off instantly. If you want it on from the
start of every share, flip **Share system audio when sharing starts** in
**Settings → Audio**.

Two details worth knowing:

- Tailscreen excludes its **own** audio output from the capture, so
  viewers' voice chat never loops back to them through the system-audio
  stream.
- On the viewer, system audio and voice are mixed together and follow the
  same speaker-device selection.

## Zoom and pan

The viewer window supports continuous content zoom, independent of window
size:

| Gesture / key | Action |
|---|---|
| Pinch | Zoom in or out at the cursor |
| ⌥ Scroll | Zoom in or out at the cursor |
| Scroll | Pan while zoomed in |
| Double-tap (trackpad smart-magnify) | Toggle 2× zoom |
| `⌥⌘+` / `⌥⌘-` | Zoom in / out (viewport center) |
| `⌘0` | Reset zoom and window size |

Zoom is anchored under the cursor — the pixel you're pointing at stays
put while everything magnifies around it — and panning is clamped so you
can't scroll the video off-screen. The **View** menu's Actual Size /
Zoom to 50% / Zoom to 200% entries are different: those resize the
*window*, not the content.

## Remote control

A viewer can drive the sharer's machine — mouse and keyboard — but only
after an explicit grant, and only one viewer at a time. (Granting requires
a macOS or Windows sharer — see [Platform notes](#platform-notes).)

**As the viewer:** open the menubar while viewing and click **Request
Control**. You'll see "Waiting for the sharer to grant control" until the
sharer answers. Once granted, your clicks and keystrokes in the viewer
window are injected on their machine. Click **Stop controlling** when
you're done.

**As the sharer:** a request shows up as "*name* wants control" with
**Grant** and **Deny** buttons (plus a notification if the menubar is
closed). Before you grant, read the caption:

Granting gives full keyboard and mouse control of your entire computer —
not just the shared window.
{: .warning }

That's not boilerplate. The *pointer* is confined to the shared content
(a shared window or app can't be used to click your menu bar, Dock, or
taskbar), but keystrokes land wherever the sharer's OS focus is — scoping
the keyboard to one app isn't something any platform lets us do reliably,
so we don't pretend otherwise.

On macOS, the first grant prompts for **Accessibility** permission (System
Settings → Privacy & Security → Accessibility) — that's the macOS
permission for synthesizing input events, separate from Screen Recording.
The grant is refused until it's given; allow Tailscreen there and grant
again. Windows needs no equivalent permission.

Ending it: the **Stop** button in the sharing card, **File → Stop Remote
Control**, or the **⌃⌥.** panic hotkey — which is registered system-wide
only while a grant is live, so you can kill control from inside any app,
including whatever the viewer is currently driving. Control also revokes
automatically when the viewer disconnects, when they release it, or when
you stop sharing.

Don't want to be asked at all? Turn off **Allow control requests** in
**Settings → Remote control**. Requests are then declined automatically
and silently.

## Quality settings

**Settings → Quality** controls the sharing side:

- **Preset** — Low / Balanced / High / Custom. Balanced is the default and
  matches Tailscreen's original behavior; Low caps at 30 fps and 3 Mbps
  for constrained links; High spends more encoder quality. Touch any knob
  individually and the preset re-labels itself Custom.
- **Frame rate** — 15 / 30 / 60 fps cap.
- **Codec** — Automatic (HEVC with H.264 fallback) or H.264.
- **Limit bandwidth** — an optional hard ceiling, 1–50 Mbps.

The bandwidth ceiling applies live, mid-share. Frame rate and codec
changes apply the next time you start sharing. Note these are *caps*, not
targets — the adaptive congestion control still reduces bitrate and frame
rate below them when the network demands it.

## The stats overlay

The **Stats** button in the viewer toolbar toggles a live overlay:
Latency, FPS, Dropped, Decode errs, PLIs sent, FEC recovered, Bitrate,
Codec, and Connection. It's the first place to look when video quality
drops — see [Troubleshooting]({% link troubleshooting.md %}) for how to
read it.

When the connection degrades badly enough that automatic recovery is
struggling, the Stats button itself flags it ("Connection degraded — click
for stats") so you don't need the overlay open to notice.

## Keyboard shortcuts

Press **⇧⌘/** in the viewer window (or click the **?** button in its
toolbar, or pick **Help → Keyboard Shortcuts**) to bring up a cheat sheet
listing everything below. Hovering any toolbar button also surfaces its
shortcut. (These are the macOS app's shortcuts; the in-app cheat sheet is
always the authority for the build you're running.)

| Shortcut | Action |
|---|---|
| `1`–`6` or `⌘1`–`⌘6` | Pick a drawing tool (Pen, Line, Arrow, Rect, Oval, Click) |
| `⌘Z` | Undo the last annotation you drew |
| `⇧⌘⌫` | Clear all annotations |
| Right-click on the canvas | Clear all annotations |
| `Esc` | Cancel the in-progress drag |
| `⌥⌘+` / `⌥⌘-` | Zoom the video in / out |
| `⌘0` | Reset zoom and window size |
| `⌃⌥M` | Toggle the microphone on/off (works system-wide, even when Tailscreen isn't focused) |
| `⌃⌥.` | Sharer only: instantly revoke remote control (system-wide, active only while a grant is live) |
| `⌘W` | Disconnect the viewer |
| `⌘Q` | Quit Tailscreen |
| `⇧⌘/` | Show/hide the keyboard-shortcut overlay |

## Stopping

- Sharer side: **Stop Sharing** in the menu, or quit the app.
- Viewer side: **Disconnect** in the menu, or close the window.

Either way, the ephemeral tsnet nodes get torn down. Nothing to clean up.

## Testing on one machine

You can run the full peer-discovery + connection path on a single machine
using the bundled launcher:

```bash
./test-local.sh        # 2 instances
./test-local.sh 3      # N instances
```

Each child gets `TAILSCREEN_INSTANCE=<i>`, which suffixes the Tailscale
state directory and hostname (`wisp-1`, `wisp-2`, ...) so the processes
register as different tailnet nodes. Without it they share one state
directory and one machine key, the tailnet treats them as the same
device, and the **Screens** list comes back empty — the most common cause
of an empty peer list when testing locally.

The launcher also sets `TAILSCREEN_OPEN_DOOR=1` so the second instance
isn't left parked on the viewer-approval prompt — see
[Troubleshooting]({% link troubleshooting.md %}) if you're scripting your
own automation.

Logs from all children are merged into `/tmp/tailscreen-merged.log`
(`TAILSCREEN_LOG=...` to override). Ctrl-C kills the whole process group.

This setup tests Tailscale integration and peer discovery, but it does
**not** test NAT traversal — both processes share the same network stack.
For that, you need two actual machines.

## Performance: getting it to feel snappy

Tailscale tries hard to get you a direct WireGuard connection. When that
works, latency is essentially the round-trip time between the two
machines. When it falls back to a DERP relay, you'll feel it.

Things you can do:

- **Wired Ethernet on at least one end.** Wi-Fi is the largest source of
  jitter in any video pipeline; Tailscreen is no exception.
- **Disable Wi-Fi power saving.** macOS happily parks the radio between
  packets to save battery, which murders interactive latency.
- **Check `tailscale status`.** If it says `relay "..."`, you're going
  through DERP. Direct connections show as `direct`. If you're stuck on
  DERP, it's almost always a NAT or firewall issue on one side, not
  Tailscale.
- **Pause large background uploads.** Cloud sync, backups, or anything
  saturating the upstream link will crowd out the video and show up as
  stutters — pause them while you share.
- **On a genuinely bad link, pick the Low preset** in Settings → Quality.
  The adaptive machinery (bitrate, frame rate, retransmission, FEC) copes
  with loss automatically, but starting from a smaller budget gives it
  less work to do.
