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

You need a Tailscale account — the free personal tier works and doesn't
expire. Sign up at [tailscale.com](https://tailscale.com/), install
Tailscale on every machine you want to share between, then install
Tailscreen on those machines (see
[Install]({{ site.baseurl }}{% link install.md %})).

You do **not** need to register Tailscreen as a Tailscale device: it
spins up its own ephemeral tsnet node when you start sharing or
connecting, and Tailscale removes it automatically when you stop, so
your admin console stays clean.

Running your own control plane —
[headscale](https://github.com/juanfont/headscale) or a fully
airgapped tailnet — is covered in
[Self-hosted control planes]({{ site.baseurl }}{% link self-hosted.md %}).

## Platform notes

Tailscreen is one app on three platforms — macOS, Linux, and Windows —
speaking one protocol, so any of them can view or share to any other.
This page uses the macOS app's menus and shortcuts; the hub window,
share card, and viewer work the same everywhere. The honest differences:

- **Sharing works everywhere — including Wayland.** X11 captures the
  root window directly; Wayland shares through the ScreenCast portal,
  starting with your compositor's consent dialog (a Wayland session
  without a portal refuses to share and says why). Sharing a single
  window or app on Linux also goes through the portal — the button
  appears only when one exists.
- **Remote control** works in both roles everywhere — requesting as a
  viewer, granting as a sharer. Linux injects via X11's XTEST extension;
  when it's absent, viewers never see a Request Control button.
- **Voice works everywhere; system-audio capture is macOS-only today.**
  **Share System Audio** exists only on the macOS sharer — viewers on
  every platform play it back.
- **Permissions:** Screen Recording and Accessibility prompts are macOS
  concepts; Linux and Windows have no equivalent gate.
- **Signing in is something you start.** No app begins a browser
  sign-in you didn't ask for. Once signed in, launching the app restores
  the session silently; if it's expired, the tailnet card says so.

The full feature-by-feature comparison lives in
[Platform support]({{ site.baseurl }}{% link platform-support.md %}).

## Sharing your screen

1. Click the 📺 in the menubar, or open the Tailscreen window.
2. Pick **Choose what to share…** — the native picker opens: a display,
   a single window, or one or more apps.
3. On a Mac, approve Screen Recording if asked. (See
   [Install → Permissions]({{ site.baseurl }}{% link install.md %}#permissions) —
   it only takes effect after a relaunch.)
4. The first time you ever share, Tailscale opens a browser tab to log
   you in; after that it's one click.

No meeting to create, no link to copy: the screen is up, people on your
tailnet can connect, and by default each one waits for your approval
before they see anything (see [Approving viewers](#approving-viewers)).

### The sharing card

Once a share is up, everything about it lives in one card: a live
preview of what viewers are seeing, the resolution and viewer count,
session buttons (**Change Source…**, **Draw**, mic, **Share System
Audio**, **Stop Sharing**), the viewer list with its approval prompts,
the approval toggle, **Share via Link**, and the mic/speaker device
pickers.

On macOS that card is the same one in two places — the menubar 📺 and
the Tailscreen window. Use whichever you're already looking at. On
Linux and Windows it lives in the hub window.

### Changing what you share mid-session

While sharing, pick **Change Source…** in the sharing card. It reopens the
picker without disconnecting anyone — viewers see a brief pause and then
the new content. Annotations are cleared on both ends when the source
changes, so stale strokes don't float over the new content.

### Cloaked Apps: hiding apps from viewers

Some apps just shouldn't be on stream — Messages, Mail, your password
manager. Add them once in **Settings → Cloaked Apps** and their windows
are excluded from every whole-display share, so there's no need to
clean up your screen first. The **Add App…** menu lists your running
apps; each entry has a **Remove** button, and **Hide cloaked apps while
sharing** lets you temporarily disable cloaking without losing the
list.

The rules:

- **Applies to display shares only** — a window or app share already
  limits capture to what you picked, so there's nothing to cloak.
- **An explicit pick wins.** Deliberately sharing a cloaked app (window
  or app share) shares it — a standing default never overrides a
  deliberate choice.
- **It's live.** Editing the list mid-share, or launching a cloaked
  app, applies within a second or two; viewers see a brief pause while
  the capture pipeline rebuilds.
- Cloaked windows are excluded at capture time — the pixels never
  reach the encoder. Viewers just see your wallpaper (or whatever's
  behind the window) in their place.

## Viewing a shared screen

1. Open the Tailscreen window — click its Dock icon, or pick **Open
   Tailscreen** in the menubar.
2. Find the sharer in the **Screens** list — search by name or IP, or
   filter to screens currently being shared (a green chip carries the
   share's name).
3. Click their row.

A window opens. You're done — unless the sharer has viewer approval on
(the default), in which case it says "Connecting to *name*…" and shows
a waiting placard (with a Cancel button) until they accept you.

On macOS the viewer window remembers its size and position across
launches, opens on the screen you're working on, and supports full
screen (**View → Enter Full Screen**, ⌃⌘F).

If the share ends — sharer stops, connection drops, or it times out —
the viewer says what happened, with a **Reconnect** button and a way
back to the screens list, on any platform. Video problems that don't
end the session — a codec fallback, a stall — appear as a dismissible
banner instead of a modal, leaving the picture up: at the top of the
window on macOS, carrying its own Reconnect; as a strip above the
video on Linux and Windows, with **Stop** as the way back to the list.

Rows are labelled by machine name. Every install joins your tailnet as
`tailscreen-<machine>` — the list drops that prefix, but the Tailscale
admin console still shows the full name.

Expand a row's chevron for a look before you connect: the live share's
resolution and codec, the peer's copyable MagicDNS name (where the
full `tailscreen-…` hostname still shows) and IP, and a Route line
giving the current Tailscale path — direct or DERP-relayed — with a
rough latency estimate.

## Approving viewers

**Require approval for new viewers** is on by default. A connecting
viewer waits on their Connecting screen while your sharing card shows a
row for them with four choices:

- **Accept** — admit them, this once.
- **Always Allow** — admit them now and automatically in the future.
- **Deny** — reject them, this once. They see "Connection Declined".
- **Deny & Block** — reject them now and automatically in the future.
  Blocking someone who's *already* connected kicks them out too.

Once connected, each viewer row also has a ✕ that disconnects them on
the spot — one-time only ("Disconnected by Sharer"), so they can
reconnect and go through approval again. For good, use **Deny & Block**
instead.

If the menubar isn't open you get a notification ("Viewer Wants to
Connect") with **Accept**/**Deny** on the banner itself; it breaks
through Do Not Disturb and Focus since someone is waiting on it.
Clicking the banner opens Tailscreen; swiping it away decides nothing.

Remembered decisions live in **Settings → Viewers** under "Remembered
viewers" (removable any time), keyed to the peer's stable Tailscale
node identity rather than IP or hostname, so a renamed machine stays
remembered.

To let anyone on the tailnet connect instantly, as before, turn the
approval toggle off in **Settings → Viewers**. Blocked peers stay
blocked even then — the deny list outranks the toggle.

## Sharing via link (guests)

Everything above assumes both machines are on your tailnet. **Share via
Link** is the way in for someone who isn't — no Tailscale account, no
install ceremony beyond Tailscreen itself.

Flip **Share via Link** in the sharing card. Tailscreen mints a one-off
link (a `tailscreen:` URL wrapping a `tc…` token), with the same four
buttons under it on every platform:

- **Copy Link** — the `tailscreen:` URL; opening it on a machine with
  Tailscreen installed lands in the join screen with the token filled
  in.
- **Copy Web Link** — the `https:` form, opening the share in a browser
  with nothing installed (see *Joining* below).
- **Copy Token** — the bare token, for pasting into the join screen.
- **New Link** — replaces the link with a fresh one; the old one stops
  working immediately and drops any current guests.

Guests knock, they don't walk in: **every guest waits at your approval
prompt, every time** — Always Allow, the open-door toggle, and accepted
share requests deliberately don't apply, since a link gets forwarded
and you can't know who holds it. Guest rows are badged **Guest** and
named by a fingerprint of their cryptographic key rather than a machine
name. Denying a guest also closes their tunnel and blocks that key for
as long as the link lives, so they can't keep knocking.

The link dies when you stop sharing, flip the toggle off, or press New
Link — nothing to revoke later. To never offer the feature, turn it off
in **Settings → Link sharing** (macOS; the switch also holds a relay
override for
[self-hosting]({{ site.baseurl }}{% link self-hosted.md %})).

<figure class="ts-shot" style="max-width: 20rem; margin: 1.75rem auto;">
  <img src="{{ '/assets/screenshots/macos-welcome.png' | relative_url }}"
       alt="The Tailscreen welcome window on macOS: a Your tailnet card with a Sign in with Tailscale button, and below it a share-link card marked No account needed, holding a paste field with a Join button and a Share your screen via Link button."
       loading="lazy" decoding="async">
  <figcaption>Two ways in, before you have signed into anything.</figcaption>
</figure>

**Sharing without signing in** works too, everywhere. Every app's
welcome screen carries a **Your tailnet** card and, beside it, **A
share link** card whose **Share your screen via Link…** needs no
account. The picker opens, the share starts as a *link-only* share —
no account, no tailnet, the link is the only way in — with the same New
Link and guest controls (menu bar on macOS; the sharing view takes over
the window on Linux and Windows). Approval is still mandatory for every
guest, and Stop Sharing is the only way to end it — a link-only share
has no link-off toggle, since that would leave a share nobody can
reach.

**Joining** works everywhere — clicking a `tailscreen:` link opens the
app straight into the guest session wherever the scheme is registered
(macOS; Linux via an installed `.desktop` entry — Flatpak does this at
install, an AppImage after desktop integration; Windows via the MSIX
install) — and pasting always works:

- **macOS** — click the link, or **Join a Share…** (the link icon in the
  hub header, also offered on the sign-in screen) and paste the link or
  token.
- **Linux and Windows** — click the link, or paste it: the welcome
  screen's share-link card has a field, and once signed in **Join a
  Share…** in the hub opens the same one (joining needs no account
  either way). The Linux app also takes `tailscreen --join
  <token-or-link>` — or the link as a bare argument — on the command
  line.
- **A browser, nothing installed** — open the **web link**
  (`https://tailscreen.dev/view/#tc…`); every platform's **Copy Web
  Link** puts it on the clipboard. Opened *without* a token, the page
  shows the same join field as the apps. Chrome, Edge and Firefox
  decode the share; Safari has not been checked yet. It waits at the
  same approval placard, then shows the screen, plays audio once you
  click **Enable Audio** (browsers insist on a click), and lets you
  **draw** or **request control** under the same capability gates as
  the apps — but no microphone, and no zoom. The token stays in the URL
  *fragment*, so the hosting site never sees it; a browser can't
  hole-punch, so everything comes through the relay — at screen-share
  bitrate that wants a
  [self-hosted relay]({{ site.baseurl }}{% link self-hosted.md %})
  rather than the free ones. The page is static and self-hostable;
  `make web-viewer-bundle` folds it into one HTML file for a network
  with no web access — open the file and add `#tc…` to its URL.

You join as a guest over an encrypted tunnel; expect the waiting
placard first. Guest sessions carry the full feature set — video,
voice, annotations, and remote control — under the same capability
gates as tailnet viewers, and remote control still takes the sharer's
explicit per-request grant.

## Asking someone to share

The flow also works in reverse: expand a peer's row in the Screens list
and click **Ask to Share**. It puts a banner in their Tailscreen —
"*name* wants you to share", with **Share** and **Decline** — and a
matching notification, so they can answer without opening the app. If
they hit Share, the picker opens on their machine and you're
automatically pre-approved for the share that follows.

You'll get one of three outcomes: **Request Accepted** ("…is choosing
what to share" — click their row once their share is up), **Request
Declined**, or **No Response** ("They may be away or running an older
Tailscreen").

## Multiple accounts

Signed in to more than one tailnet — personal and a work org, say? The
account menu (the avatar in the window's header) lists every profile
with its login and tailnet name, Tailscale-style. Click one to switch;
the others stay signed in on disk, so switching back is instant and
browser-free. **Add Account…** starts a fresh sign-in; holding ⌥ over a
profile row swaps it for **Remove Account…**; the menubar's identity
strip always shows which account a new share will start on.

The same accounts live in **Settings → Accounts** (macOS), with
visible Remove buttons and an Add Account… needing no ⌥-click. To have
Tailscreen ready the moment you log in, flip **Settings → General →
Launch at login**.

## Annotations

The viewer's toolbar has drawing tools plus a color swatch — pick one
of the eight preset colors and your strokes carry it to the sharer and
every other viewer, appearing in a transparent overlay window on their
machine. Strokes ride a reliable channel separate from the video (see
[Network Protocol]({{ site.baseurl }}{% link protocol.md %})), so they
don't drop even when video frames do.

Annotations aren't persisted on either end — quit the viewer or stop
sharing and they're gone.

## Voice chat

Both sides have a mic button (on macOS, **⌃⌥M** also works system-wide,
even when unfocused — remappable in **Settings → Keyboard Shortcuts**,
which warns when another app already owns the combo). Audio travels
over the same tunnel as the video. With multiple viewers, everyone
hears everyone — the sharer relays each viewer's voice to the others.
A lossy Wi-Fi link degrades into brief soft spots rather than robotic
stutter.

## Sharing system audio

The sharing card has a **Share System Audio** button (macOS — see
[Platform notes](#platform-notes)) that captures and streams everything
your Mac plays alongside the video; **Mute System Audio** toggles it
back off instantly. To have it on from the start of every share, flip
**Share system audio when sharing starts** in **Settings → Audio**.

Two details worth knowing: Tailscreen excludes its **own** audio output
from the capture, so viewers' voice chat never loops back through the
system-audio stream; and on the viewer, system audio and voice are
mixed together and follow the same speaker-device selection.

## Zoom and pan

The viewer window supports continuous content zoom, independent of
window size:

| Gesture / key | Action |
|---|---|
| Pinch | Zoom in or out at the cursor |
| ⌥ Scroll | Zoom in or out at the cursor |
| Scroll | Pan while zoomed in |
| Double-tap (trackpad smart-magnify) | Toggle 2× zoom |
| `⌥⌘+` / `⌥⌘-` | Zoom in / out (viewport center) |
| `⌘0` | Reset zoom and window size |

Zoom is anchored under the cursor — the pixel you're pointing at stays
put while everything magnifies around it — and panning is clamped so
you can't scroll the video off-screen. The **View** menu's Actual Size /
Zoom to 50% / Zoom to 200% entries are different: those resize the
*window*, not the content.

## Remote control

A viewer can drive the sharer's machine — mouse and keyboard — but only
after an explicit grant, and only one viewer at a time. (Granting
requires a macOS or Windows sharer — see
[Platform notes](#platform-notes).)

**As the viewer:** click **Request Control** in the viewer toolbar
(also in the menubar popover; it only appears when the sharer's build
can inject input at all). It shows "Requesting…" until the sharer
answers — click again to cancel. Once granted, your clicks and
keystrokes are injected on their machine, an orange border outlines
the video, and the title bar reads "— controlling". Your scroll wheel
scrolls *their* content while you hold control; **Ctrl+wheel** still
zooms your own view. Stop with the toolbar's **Stop Controlling**,
**File → Release Remote Control**, or **⌃⌥.** (the one chord never
forwarded to the sharer; remappable in Settings → Keyboard Shortcuts).

**As the sharer:** a request shows up as "*name* wants control" with
**Grant**/**Deny** buttons (plus a matching notification if the
menubar is closed — granting from the banner needs the Mac unlocked).
Before you grant, read the caption:

Granting gives full keyboard and mouse control of your entire computer —
not just the shared window.
{: .warning }

The *pointer* is confined to the shared content (a window or app share
can't click your menu bar, Dock, or taskbar), but keystrokes land
wherever the sharer's OS focus is — no platform lets us scope the
keyboard to one app reliably.

On macOS, the first grant prompts for **Accessibility** permission
(System Settings → Privacy & Security → Accessibility) — separate from
Screen Recording. The grant is queued while you make the trip ("Waiting
for Accessibility permission…") and completes on its own once granted.
Windows needs no equivalent permission.

Ending it: the **Stop** button in the sharing card, **File → Stop
Remote Control**, or the **⌃⌥.** panic hotkey — registered system-wide
only while a grant is live, so it works from inside any app, including
whatever the viewer is driving. Control also revokes automatically on
viewer disconnect, release, or Stop Sharing.

To skip being asked at all, turn off **Allow control requests** in
**Settings → Remote control**; requests are then declined automatically
and silently.

## Quality settings

**Settings → Quality** controls the sharing side:

- **Preset** — Low / Balanced / High / Custom. Balanced is the default;
  Low caps at 30 fps and 3 Mbps for constrained links; High spends more
  encoder quality. Touching any knob individually re-labels the preset
  Custom.
- **Frame rate** — 15 / 30 / 60 fps cap.
- **Codec** — Automatic (HEVC with H.264 fallback), HEVC, or H.264.
  Explicit HEVC never falls back, so viewers stuck on H.264 won't be
  able to watch (the pane says so when picked). A sharer with no HEVC
  encoder (Windows, and Linux without libx265) starts in H.264 instead;
  the stats overlay shows the codec in use.
- **Encoder quality** — a 0.30–1.00 quality/bitrate slider, what the
  presets mostly differ on, unlocked only on Custom.
- **Limit bandwidth** — an optional hard ceiling, 1–50 Mbps. Off means
  *automatic*, not unlimited: the rate derives from captured resolution
  and frame rate, bounded at 50 Mbps. That bound only bites above 4K — a
  4K 60 fps capture already derives ~40 Mbps, while 5K/6K would derive
  ~98 Mbps but stays capped at 50.

**Settings → Color** holds the 10-bit and HDR capture opt-ins that used
to require environment variables, applying next time you share. HDR
needs a display with EDR headroom, and viewers must be able to decode
10-bit video — the share stays 8-bit for everyone while one that can't
(Linux and Windows, today) is watching, with no other side effects.

The bandwidth ceiling applies live, mid-share. Frame rate, codec,
encoder quality, and color changes apply the next time you start
sharing. Note these are *caps*, not targets — the adaptive congestion
control still reduces bitrate and frame rate below them when the
network demands it.

## The stats overlay

The **Stats** button in the viewer toolbar toggles a live overlay:
Latency, FPS, Dropped, Decode errs, PLIs sent, FEC recovered, Bitrate,
Codec, and Connection — the first place to look when video quality
drops (see
[Troubleshooting]({{ site.baseurl }}{% link troubleshooting.md %}) for
how to read it). When degradation is bad enough that automatic recovery
is struggling, the button itself flags it ("Connection degraded — click
for stats") so you don't need the overlay open to notice.

## Keyboard shortcuts

Press **⇧⌘/** (a floating panel while sharing), click the **?** button
in the viewer toolbar, or pick **Help → Keyboard Shortcuts**, for a
cheat sheet listing everything below, split by role for remote control.
Esc dismisses it; hovering a toolbar button also surfaces its shortcut.
(These are the macOS shortcuts; the in-app cheat sheet is always the
authority for the build you're running.)

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

Either way, the ephemeral tsnet nodes get torn down. Nothing to clean
up.

## Testing on one machine

You can run the full peer-discovery + connection path on a single
machine using the bundled launcher:

```bash
./test-local.sh        # 2 instances
./test-local.sh 3      # N instances
```

Each child gets `TAILSCREEN_INSTANCE=<i>`, suffixing the Tailscale
state directory and hostname (`wisp-1`, `wisp-2`, ...) so they register
as different tailnet nodes. Without it they share one state directory
and machine key, the tailnet treats them as the same device, and the
**Screens** list comes back empty — the most common cause of an empty
peer list when testing locally.

The launcher also sets `TAILSCREEN_OPEN_DOOR=1` so the second instance
isn't parked on the viewer-approval prompt — see
[Troubleshooting]({{ site.baseurl }}{% link troubleshooting.md %}) if
scripting your own automation. Logs from all children merge into
`/tmp/tailscreen-merged.log` (`TAILSCREEN_LOG=...` to override); Ctrl-C
kills the whole process group.

This tests Tailscale integration and peer discovery, but **not** NAT
traversal — both processes share the same network stack. For that,
use two actual machines.

## Performance: getting it to feel snappy

Tailscale tries hard to get you a direct WireGuard connection, where
latency is essentially round-trip time between the two machines; a
DERP relay fallback is felt. Things you can do:

- **Wired Ethernet on at least one end.** Wi-Fi is the largest source
  of jitter in any video pipeline.
- **Disable Wi-Fi power saving.** macOS parks the radio between packets
  to save battery, which murders interactive latency.
- **Check `tailscale status`.** `relay "..."` means DERP; `direct`
  means a direct connection. Stuck on DERP is almost always a NAT or
  firewall issue on one side, not Tailscale.
- **Pause large background uploads.** Cloud sync, backups, or anything
  saturating the upstream link crowds out the video and shows up as
  stutters.
- **On a genuinely bad link, pick the Low preset** in Settings →
  Quality — adaptive loss recovery works better from a smaller budget.
</content>
