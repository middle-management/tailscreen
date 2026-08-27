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
(see [Install]({{ site.baseurl }}{% link install.md %})).

You do **not** need to register Tailscreen as a Tailscale device. It spins
up its own ephemeral tsnet node when you start sharing or connecting, and
Tailscale removes the node automatically when you stop. Your admin console
stays clean.

If you'd rather not use Tailscale's hosted control plane — you run
[headscale](https://github.com/juanfont/headscale), say, or you want a
fully airgapped tailnet — see
[Self-hosted control planes]({{ site.baseurl }}{% link self-hosted.md %}).

## Platform notes

Tailscreen is one app on three platforms — macOS, Linux, and Windows — and
they all speak the same protocol, so any of them can view or share to any
other. This page uses the macOS app's menus and keyboard shortcuts in its
examples; the hub window, share card, and viewer work the same everywhere.
The honest differences:

- **Sharing works everywhere — including Wayland.** On Linux, an X11
  session captures the root window directly; a Wayland session shares
  through the ScreenCast portal, so the share starts with your
  compositor's consent dialog. A Wayland session without a portal refuses
  to share and says why. Sharing a single window or app on Linux also
  goes through the portal — the button appears only when one exists.
- **Remote control** works in both roles on every platform — requesting as
  a viewer, and granting as a sharer. (Linux injects via X11's XTEST
  extension; when it's absent, the capability isn't advertised and viewers
  never see a Request Control button.)
- **Voice works everywhere; system-audio capture is macOS-only today.**
  The mic button exists on all three apps. **Share System Audio** exists
  only on the macOS sharer — viewers on every platform play it back.
- **Permissions:** Screen Recording and Accessibility prompts are macOS
  concepts. Linux and Windows have no equivalent gate.

The full feature-by-feature comparison lives in
[Platform support]({{ site.baseurl }}{% link platform-support.md %}).

## Sharing your screen

1. Click the 📺 in the menubar, or open the Tailscreen window.
2. Pick **Choose what to share…**. The native picker opens — choose a
   display, a single window, or one or more apps.
3. On a Mac, approve Screen Recording if macOS asks. (See
   [Install → Permissions]({{ site.baseurl }}{% link install.md %}#permissions) — the
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

A window opens. You're done — unless the sharer has viewer approval on
(the default), in which case the window says "Connecting to *name*…" and
shows a waiting placard (with a Cancel button) until they accept you.

On macOS the viewer window behaves like a proper Mac window: it remembers
its size and position across launches, opens on the screen you're working
on, and supports full screen (**View → Enter Full Screen**, ⌃⌘F).

If the share ends — the sharer stops, the connection drops, or it times
out — the viewer doesn't just vanish, on any platform: it says what
happened, with a **Reconnect** button that rejoins the same peer and a
way back to the screens list. On macOS, transient video problems (a
codec fallback, a stall) additionally appear as a banner at the top of
the window instead of a modal alert; the stall banner carries its own
Reconnect.

Rows are labelled by machine name. Every Tailscreen install joins your
tailnet as `tailscreen-<machine>` — that prefix is how peers recognise each
other, so the list drops it and shows just the machine. In the Tailscale
admin console the same device still appears with its full name.

Want a look before you connect? Expand a row with its chevron: you get the
live share's resolution and codec, the peer's MagicDNS name and IP (both
copyable, and the MagicDNS name is where the full `tailscreen-…` hostname
still shows), and a Route line showing the current Tailscale path — direct
or DERP-relayed — with a rough latency estimate.

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
isn't open — with **Accept** and **Deny** on the banner itself, so you can
answer without leaving what you're sharing. It breaks through Do Not Disturb
and Focus, since someone is stuck behind it. Clicking the banner instead of a
button just opens Tailscreen; swiping it away decides nothing.

Remembered decisions live in **Settings → Viewers** under
"Remembered viewers", where you can remove entries any time. They're keyed
to the peer's stable Tailscale node identity, not its IP or hostname, so a
renamed machine stays remembered.

If you'd rather have the old anyone-on-the-tailnet-connects-instantly
behavior, turn the toggle off in **Settings → Viewers**. Blocked peers
stay blocked even then — the deny list outranks the toggle.

## Sharing via link (guests)

Everything above assumes both machines are on your tailnet. **Share via
Link** is the way in for someone who isn't — no Tailscale account, no
install ceremony beyond Tailscreen itself.

While sharing, flip **Share via Link** in the sharing card (the menubar
card on macOS; the hub's share card on Linux and Windows, where the link
appears as selectable text to copy). Tailscreen mints a one-off link (a
`tailscreen:` URL wrapping a `tc…` token). On macOS it comes with three
buttons:

- **Copy Link** — the `tailscreen:` URL. On a machine with Tailscreen
  installed, opening it lands in the join screen with the token filled in.
- **Copy Token** — the bare token, for pasting into the join screen by
  hand.
- **New Link** — replaces the link with a fresh one. The old link stops
  working immediately and any current guests are dropped.

Guests knock, they don't walk in: **every guest waits at your approval
prompt, every time** — Always Allow, the open-door toggle, and accepted
share requests deliberately don't apply to them, because a link gets
forwarded and you can't know who holds it. Guest rows are badged
**Guest** and named by a short fingerprint of their cryptographic key
rather than a machine name (guests don't have one you could trust).
Denying a guest also closes their tunnel and blocks that key for as long
as the link lives, so a denied guest can't keep knocking.

The link dies when you stop sharing, flip the toggle off, or press New
Link — there is nothing to revoke later. If you never want the feature
offered, turn it off in **Settings → Link sharing** (macOS; the switch
also holds a relay override for
[self-hosting]({{ site.baseurl }}{% link self-hosted.md %})).

**Sharing without signing in** works too: the macOS welcome screen offers
**Share your screen via Link…** alongside the sign-in button. The picker
opens, the share starts as a *link-only* share — no Tailscale account,
no tailnet, the link is the only way in — and the menubar card shows the
link with the same Copy / New Link / guest controls. Approval is still
mandatory for every guest, and Stop Sharing is the way to end it (a
link-only share has no link-off toggle: turning off its only transport
would leave a share running that nobody can reach).

**Joining** works on all three platforms — clicking a `tailscreen:` link
opens the app straight into the guest session wherever the scheme is
registered (macOS; Linux via an installed `.desktop` entry — Flatpak does
this at install, an AppImage after desktop integration; Windows via the
MSIX install), and pasting always works:

- **macOS** — click the link, or **Join a Share…** (the link icon in the
  hub header, also offered on the sign-in screen) and paste the link or
  token.
- **Linux and Windows** — click the link, or **Join a Share…** in the hub
  (offered before sign-in too — joining needs no account). The Linux app
  also takes `tailscreen --join <token-or-link>` — or the link as a bare
  argument — on the command line.

You join as a guest over an encrypted tunnel; the sharer has to approve
you before you see anything, so expect the waiting placard first. Guest
sessions carry the full feature set: video, voice, **annotations, and
remote control** — the same capability gates apply as for tailnet
viewers (a sharer that can't render strokes or inject input simply
doesn't offer those tools), and remote control still takes the sharer's
explicit per-request grant. Sharing *without signing in at all* (a
link-only share) is macOS-only today — see the
[platform matrix]({{ site.baseurl }}{% link platform-support.md %}).

## Asking someone to share

The flow also works in reverse. Expand a peer's row in the Screens list
and click **Ask to Share** to ask that peer to share *their* screen.
Clicking it puts a banner in their Tailscreen — "*name* wants you to
share", with **Share** and **Decline** buttons — and a notification carrying
the same two buttons, so they can answer without opening the app. If
they hit Share, the picker opens on their machine, and you're automatically
pre-approved for the share that follows — no second approval round-trip.

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

The same accounts also live in **Settings → Accounts** (macOS) with
visible per-row Remove buttons and an Add Account… — no hidden ⌥-click
required. And if you want Tailscreen ready the moment you log in, flip
**Settings → General → Launch at login**.

## Annotations

The viewer's toolbar has drawing tools, plus a color swatch — pick one of
the eight preset colors and your strokes carry it to the sharer and every
other viewer. Doodle on the sharer's screen and
your strokes appear in a transparent overlay window on their machine.
Strokes ride a reliable channel separate from the video (see
[Network Protocol]({{ site.baseurl }}{% link protocol.md %})), so they
don't drop even when video frames do.

Annotations aren't persisted on either end — quit the viewer or stop
sharing and they're gone.

## Voice chat

Both sides have a mic button (on macOS, **⌃⌥M** also works system-wide,
even when Tailscreen isn't focused — remappable in **Settings → Keyboard
Shortcuts**, which also warns when another app already owns the combo).
Audio travels over the same tunnel as the video.
With multiple viewers, everyone hears everyone — the sharer relays each
viewer's voice to the other viewers. A lossy Wi-Fi link degrades into
brief soft spots rather than robotic stutter.

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

**As the viewer:** click **Request Control** in the viewer window's
toolbar (it's also in the menubar popover; the toolbar button only
appears when the sharer's build can inject input at all). The button
shows "Requesting…" until the sharer answers — click it again to cancel.
Once granted, your clicks and keystrokes in the viewer window are
injected on their machine, an orange border outlines the video, and the
title bar reads "— controlling" so there's no mistaking whose Mac your
keystrokes land on. Stop with the toolbar's **Stop Controlling**,
**File → Release Remote Control**, or **⌃⌥.** typed in the viewer window
(the one chord that's never forwarded to the sharer; it follows the
remap in Settings → Keyboard Shortcuts).

**As the sharer:** a request shows up as "*name* wants control" with
**Grant** and **Deny** buttons (plus a notification, carrying the same two
buttons, if the menubar is closed — granting from the banner needs the Mac
unlocked). Before you grant, read the caption:

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
The grant you clicked is queued while you make the trip to System
Settings (the request's row says "Waiting for Accessibility permission…")
and completes on its own the moment the permission lands. Windows needs
no equivalent permission.

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
- **Codec** — Automatic (HEVC with H.264 fallback), HEVC, or H.264.
  Explicit HEVC is the no-safety-net choice: it never falls back, so
  viewers that can only decode H.264 won't be able to watch — the pane
  says so when you pick it.
- **Encoder quality** — a 0.30–1.00 slider for the encoder's
  quality/bitrate trade-off. It's what the presets mostly differ on, so it
  unlocks only on Custom (the other presets just show their value).
- **Limit bandwidth** — an optional hard ceiling, 1–50 Mbps.

**Settings → Color** holds the 10-bit and HDR capture opt-ins that used
to require environment variables. Both apply the next time you start
sharing; HDR needs a display with EDR headroom, and viewers have to be
able to decode 10-bit video — each one says so when it connects, and the
share stays at 8-bit for everyone while one that can't is watching (the
Linux and Windows viewers can't yet). Nothing breaks either way; you just
don't get the extra depth.

The bandwidth ceiling applies live, mid-share. Frame rate, codec,
encoder quality, and color changes apply the next time you start sharing.
Note these are *caps*, not targets — the adaptive congestion control
still reduces bitrate and frame rate below them when the network demands
it.

## The stats overlay

The **Stats** button in the viewer toolbar toggles a live overlay:
Latency, FPS, Dropped, Decode errs, PLIs sent, FEC recovered, Bitrate,
Codec, and Connection. It's the first place to look when video quality
drops — see [Troubleshooting]({{ site.baseurl }}{% link troubleshooting.md %}) for how to
read it.

When the connection degrades badly enough that automatic recovery is
struggling, the Stats button itself flags it ("Connection degraded — click
for stats") so you don't need the overlay open to notice.

## Keyboard shortcuts

Press **⇧⌘/** — in the viewer window *or while sharing* (there it opens
in its own floating panel) — or click the **?** button in the viewer
toolbar, or pick **Help → Keyboard Shortcuts**, to bring up a cheat sheet
listing everything below, with the remote-control shortcuts split by
role. Esc dismisses it. Hovering any toolbar button also surfaces its
shortcut. (These are the macOS app's shortcuts; the in-app cheat sheet is
always the authority for the build you're running.)

| Shortcut | Action |
|---|---|
| `1`–`6` or `⌘1`–`⌘6` | Pick a drawing tool (Pen, Line, Arrow, Rect, Oval, Click) |
| `⌘Z` | Undo the last annotation you drew |
| `⇧⌘⌫` | Clear all annotations |
| Right-click on the canvas | Clear all annotations |
| `Esc` | Dismiss the cheat sheet, else cancel the in-progress drag |
| `⌥⌘+` / `⌥⌘-` | Zoom the video in / out |
| `⌘0` | Reset zoom and window size |
| `⌃⌘F` | Enter or exit full screen in the viewer window |
| `⌃⌥M` | Toggle the microphone on/off (works system-wide, even when Tailscreen isn't focused; remappable in Settings → Keyboard Shortcuts) |
| `⌃⌥.` | Sharer: instantly revoke remote control (system-wide, active only while a grant is live). Viewer: release the control you hold — the one chord never forwarded to the sharer. Both remappable in Settings → Keyboard Shortcuts |
| `⌘W` | Disconnect the viewer |
| `⌘Q` | Quit Tailscreen |
| `⇧⌘/` | Show/hide the keyboard-shortcut overlay (viewing or sharing) |

## Stopping

- Sharer side: **Stop Sharing** in the menu, or quit the app.
- Viewer side: **Disconnect** (⌘W) in the menu, or close the window.
  Both surfaces' viewing cards also have a **Show Window** button when
  the viewer window is buried.

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
[Troubleshooting]({{ site.baseurl }}{% link troubleshooting.md %}) if you're scripting your
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
  The adaptive machinery copes with loss automatically, but starting from
  a smaller budget gives it less work to do.
