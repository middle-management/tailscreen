---
title: Troubleshooting
nav_order: 9
permalink: /troubleshooting/
---

# Troubleshooting
{: .no_toc }

1. TOC
{:toc}

If something's broken, it's almost certainly one of the things on this
page — ordered from boring permission stuff to interesting failure modes.
The walkthroughs name macOS surfaces (System Settings, Console.app), but
the connection-side failure modes and fixes are the same on Linux and
Windows.

## "Permission Denied" when capturing screen

Screen Recording either hasn't been granted yet, or it was granted but
Tailscreen wasn't relaunched.

1. **System Settings → Privacy & Security → Screen Recording.**
2. Toggle **Tailscreen** on. (If you launched it from Terminal, you may
   need to toggle Terminal on instead — macOS attaches the permission to
   the launching process.)
3. **Quit Tailscreen completely and relaunch it.** macOS does not push the
   new permission to a running process, so a restart is required.

## "Connection Failed"

Walk this checklist in order:

1. Open the Tailscale app on both machines and confirm they're both
   showing each other in the device list. If they're not both green, this
   is a Tailscale problem first, a Tailscreen problem second.
2. Confirm the hostname or IP. Expanding the sharer's row in the
   viewer's **Screens** list shows its MagicDNS name and IP.
3. Check your tailnet ACLs allow TCP **and** UDP on port 7447 from the
   viewer to the sharer. The default Tailscale ACL is "everything to
   everything" and will work fine. If you've tightened ACLs, double-check
   that 7447 is still allowed.
4. Try `tailscale ping <viewer-hostname>` from the sharer's command line.
   If that fails, so will Tailscreen — the issue is in the underlying
   Tailscale connection.

## Viewer stuck on the Connecting screen

If the connection succeeds but the window sits on "Connecting to
*name*…" with the waiting placard, you're most likely **waiting in the
sharer's approval queue**. "Require approval for new viewers" is on by
default: the sharer's menubar *and* hub window (and a notification) are
showing an Accept/Deny row for you, and nothing happens until they click
it. Ask them to look at either surface — or press the placard's Cancel
button to give up.

If you instead get **"Connection Declined"**, the sharer denied you — or
has previously hit "Deny & Block" on your machine, in which case every
future attempt is rejected automatically until they remove you under
**Settings → Viewers → Remembered viewers**.

If you're scripting Tailscreen (CI, kiosks, `test-local.sh`-style
automation) and there's no human to click Accept, launch the **sharer**
with `TAILSCREEN_OPEN_DOOR=1` to force the approval gate off. Don't use
it outside automation — it's the "anyone on the tailnet connects
instantly" switch.

## Two local instances see no peers

This is by far the most common cause of an empty peer list when testing
locally:

Both instances are using the same Tailscale state directory at
`~/Library/Application Support/Tailscreen/tailscale`. They both end up
with the same machine key. The tailnet thinks they're the same device.
The **Screens** list excludes the device it's running on, so each
instance sees an empty list.
{: .note }

Fix: use `./test-local.sh` (which sets `TAILSCREEN_INSTANCE` per child),
or set it manually:

```bash
TAILSCREEN_INSTANCE=1 Apps/macOS/.build/debug/Tailscreen
TAILSCREEN_INSTANCE=2 Apps/macOS/.build/debug/Tailscreen
```

Each instance gets its own state directory and its own hostname. Now they
see each other.

## Stuck on a DERP relay

`tailscale status` will show one of `direct` or `relay "<region>"` for
each peer. If you're on DERP, latency goes up and you can feel it.

DERP fallback happens when one or both ends can't establish a direct
WireGuard connection. Common causes:

- **Symmetric NAT** on at least one end — common on cellular and on some
  enterprise Wi-Fi.
- **Aggressive firewall** blocking the UDP probes Tailscale uses for hole
  punching.
- **VPN software** intercepting your traffic in a way that breaks
  Tailscale's path discovery.

Read the Tailscale [troubleshooting docs](https://tailscale.com/kb/1023/troubleshooting)
on direct connections — that's the right place to fix it.

## Low FPS or stuttering on a direct connection

If `tailscale status` confirms `direct` and it's still bad:

- Run `iperf3` between the two machines and check the actual end-to-end
  bandwidth. Wi-Fi delivers a small fraction of its negotiated link rate
  in the real world.
- If the result is bad: switch one or both ends to wired Ethernet. That's
  usually the biggest single improvement you can make.
- If the result is good and the video is still bad: open Console.app,
  filter for `Tailscreen`, and look for VideoToolbox errors. Encoder
  starvation or decoder backpressure produces logs.
- Disable Wi-Fi power saving on both ends.

## "Connection degraded" badge in the viewer toolbar

The Stats button turning into a "Connection degraded — click for stats"
badge means video decoding has been failing repeatedly and the automatic
recovery ladder is already several rungs in. The viewer escalates
through: request a keyframe → recreate the decoder session → show this
badge → and finally a **"Video has stalled"** banner at the top of the
window if several seconds pass with no successful decode.

The badge is informational — recovery keeps running behind it, and a
single good keyframe clears it. If it persists, click it: the stats
overlay's **PLIs sent**, **Dropped**, and **FEC recovered** rows tell you
whether you're looking at network loss (fix the network — see the DERP
and Wi-Fi sections above) versus **Decode errs** climbing on a clean
connection (a decoder problem — reconnect, and check Console.app for
VideoToolbox errors). If you get all the way to the stalled banner, its
**Reconnect** button is the reliable reset.

The Linux and Windows viewers run the same recovery ladder (it lives in
the shared core) with a simpler surface: there is no degraded badge —
the decoder is reset at the same rung, and a persistent stall shows the
same **"Video has stalled"** message in place of the video (Linux) or on
the window's status line (Windows). Reconnecting to the screen is the
equivalent reset there.

## Remote control grant fails asking for Accessibility

Granting control the first time pops **"Accessibility Permission
Needed"**. This is expected: injecting mouse and keyboard events requires
the Accessibility permission, which is separate from Screen Recording.
Open **System Settings → Privacy & Security → Accessibility** and toggle
Tailscreen on — the grant you clicked is queued (the request's row says
"Waiting for Accessibility permission…") and completes on its own the
moment the permission lands, as long as that viewer is still asking. No
second click needed. If you launched Tailscreen from Terminal, the
permission may need to go to Terminal instead, same as with Screen
Recording.

## Capture restarts by itself mid-share

Viewers see a brief pause, the sharer's log shows a helper restart. The
parent process watches the capture helper for liveness and restarts it if
a live helper goes silent for 15 seconds — that's the hung-capture
watchdog catching an SCStream that wedged without exiting, and the
restart *is* the fix.

A completely static screen does **not** trip this: the helper emits a
~1 Hz heartbeat off ScreenCaptureKit's idle frames even when no pixels
change, so "nothing on screen is moving" and "capture is dead" are
distinguishable. You can share a motionless dashboard for hours.

If the watchdog misfires in some environment we haven't met,
`TAILSCREEN_DISABLE_HELPER_WATCHDOG=1` is the escape hatch — but file an
issue, because a legitimate 15-second silence from a live helper isn't
supposed to exist.

## Black viewer window, no frames at all

Two flavors:

**Toolbar visible, video area is black.** The connection succeeded but no
keyframe has arrived (or the SPS/PPS for the current keyframe got lost).
Hit **Disconnect** and reconnect — that triggers a fresh keyframe from the
encoder. If it happens repeatedly, see the previous section about Wi-Fi
quality.

**Window is entirely black, no toolbar.** Something failed during window
construction. Check Console.app for Metal or VideoToolbox errors. Restart
both apps as a first move.

## Colours look washed out, or shadows look crushed

Open the viewer's stats overlay (macOS: **Stats** in the viewer toolbar;
Linux and Windows: the **Stats** button) and read the colour line. It shows
what the sender said about the stream — for example `BT.709 · limited` or
`P3 · full`.

The two ranges use the 0–255 byte differently: *limited* puts black at 16
and white at 235, *full* uses the whole byte. Decoding one as the other is
what greys out blacks or clips highlights. The viewers pick their maths from
what the stream says, so a mismatch here means the sender is mislabelling
its video rather than that the viewer guessed wrong — worth a bug report,
with the colour line and both platforms named.

The macOS viewer's line shows the colour primaries only (`P3`, `BT.2020 ·
PQ`, or `—` for a plain BT.709 stream that tags nothing). It shows no range
because its decoder hands the renderer RGB, by which point the stream's
range no longer exists to report.

## The share link won't mint, or a guest can't connect

Creating a link needs the network twice: once to fetch the DERP relay map
and once to hold the relay connection the token names. "Couldn't create
the link" almost always means one of those was unreachable — check the
sharer's connectivity (or, if you set a custom relay under **Settings →
Link sharing**, that your override URL serves a valid relay map).

A guest stuck on the waiting placard is usually not stuck: guest approval
is mandatory, every join, so nothing happens until the sharer presses
Accept — check the sharer's screen (or notifications) for the prompt. If
the guest instead fails outright, the usual causes in order: the link was
**rotated or the share stopped** (each link dies with its share — ask for
a fresh one); the token was mangled in transit (paste it again — the
whole `tailscreen://join?token=…` line or the bare `tc…` token both
work); or the guest's network blocks the outbound HTTPS/TLS connection
the relay bootstrap needs.

## The browser viewer: a 404, a blank stage, or "codec unsupported"

The web form of a share link opens a page instead of an app
([Usage]({{ site.baseurl }}{% link usage.md %}#sharing-via-link-guests)),
and its failure modes are mostly the browser's:

- **`tailscreen.dev/view/` is a 404.** The root URL — the one the apps'
  **Copy Web Link** produces — only exists once a stable release ships the
  page; until then the same page is served from
  `https://tailscreen.dev/next/view/`. Keep the `#tc…` fragment when you
  change the path; the token lives there.
- **"Waiting for approval" and nothing happens.** Same as any guest: the
  sharer has to press Accept, every join. Nothing is stuck.
- **The stage stays blank, or the page says the codec is unsupported.**
  The page decodes with the browser's own decoders (WebCodecs), and H.264
  is a *licensed* codec that not every build carries. Chrome, Edge and
  Firefox have it; plain Chromium builds and some distribution-packaged
  browsers do not, and there the page has nothing to decode with. Try one
  of the three. An HEVC share is not the problem — the page asks the
  sharer to fall back to H.264 by itself.
- **The page loads but WebCodecs is "not defined".** Browsers expose it
  only in a *secure context*: `https://` or a file opened from disk. A
  copy of the page served over plain `http://` from a LAN host will not
  decode; serve it over TLS, or use the single-file bundle
  (`make web-viewer-bundle`) straight from disk.
- **Video but no sound.** Browsers refuse to play audio until the page has
  been clicked; press **Enable audio**.
- **It stutters more than the apps do.** A browser cannot hole-punch, so
  everything it receives crosses a DERP relay, at screen-share bitrate,
  for the whole session — and on a stream, packet loss shows up as delay
  rather than as dropped frames. Tailscale's free relays are not sized for
  that; a [self-hosted relay]({{ site.baseurl }}{% link self-hosted.md %}#your-own-relay-for-share-links-derper)
  is the fix, and a native app on the same machine will always do better.

The page's **Log** button shows what it saw — codec probes, the approval
sequence, decode errors — and is what to paste into a bug report.

## Clicking a tailscreen: link does nothing

The scheme is registered by the *packaged* app, and each platform has a
gap to know about. macOS: only the released `.app` bundle registers — a
`make run` development binary never does. Linux: the Flatpak registers at
install; an AppImage only after desktop integration (AppImageLauncher or
similar); a bare binary or tarball never — use **Join a Share…** or
`tailscreen --join <link>` instead. Windows: the MSIX registers; the zip
build doesn't. Pasting the link into the join field always works
everywhere.

## The app is in English even though my system isn't

Tailscreen ships English and Swedish today; anything else falls back to
English, one string at a time, by design.

If a language you expect *is* shipped and you still get English, the string
catalog probably isn't beside the binary. It travels as a
`…_TailscreenL10n.bundle` directory — inside `Tailscreen.app/Contents/
Resources/` on macOS, next to `tailscreen` / `tailscreen.exe` on Linux and
Windows. Copying just the executable out of a tarball or zip leaves it behind,
and the app then renders in English rather than complaining.

To check which language is being picked, or to see another one without changing
your system settings:

```bash
TAILSCREEN_LANG=sv ./tailscreen
```

On Linux the language otherwise comes from `LC_ALL` / `LC_MESSAGES` / `LANG`,
on Windows from the user's default UI language, and on macOS from the ordered
list in System Settings → General → Language & Region.

## Build fails with linker errors

You ran bare `swift build` without going through `make` first. The Go
toolchain hasn't built `libtailscale.a` yet, so there's nothing to link
against. Run `make build` (or at minimum `make tailscale`) once. After
that, `swift build` works for the rest of the build tree.

## TailscaleKit submodule looks empty

You cloned without `--recurse-submodules`. Fix:

```bash
git submodule update --init --recursive
```

`Packages/TailscaleKit/upstream/libtailscale` is pinned in `.gitmodules` and
required for the build.

## Reporting a bug

If none of the above is your problem, file an issue at
[github.com/middle-management/tailscreen/issues](https://github.com/middle-management/tailscreen/issues).
Include:

- OS and version on both ends (`sw_vers` on macOS, your distro, or the
  Windows build), and the machine models.
- Tailscale version on both peers, and whether the connection is `direct`
  or via DERP (`tailscale status`).
- Relevant log lines — Console.app filtered for `Tailscreen` on macOS,
  stderr on Linux and Windows.

"It doesn't work" is hard to fix. The above is much easier.
