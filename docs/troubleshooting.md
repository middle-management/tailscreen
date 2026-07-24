---
title: Troubleshooting
nav_order: 8
permalink: /troubleshooting/
---

# Troubleshooting
{: .no_toc }

1. TOC
{:toc}

If something's broken, it's almost certainly one of the things on this
page — ordered from boring permission stuff to interesting failure modes.

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

1. Open the Tailscale menubar app on both Macs and confirm they're both
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

If the connection succeeds but you sit on "Connecting…" indefinitely,
you're most likely **waiting in the sharer's approval queue**. "Require
approval for new viewers" is on by default: the sharer's menubar (and a
notification) is showing an Accept/Deny row for you, and nothing happens
until they click it. Ask them to look at the menubar.

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

- Run `iperf3` between the two Macs and check the actual end-to-end
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
badge → and finally a **"Video Has Stalled"** alert if several seconds
pass with no successful decode.

The badge is informational — recovery keeps running behind it, and a
single good keyframe clears it. If it persists, click it: the stats
overlay's **PLIs sent**, **Dropped**, and **FEC recovered** rows tell you
whether you're looking at network loss (fix the network — see the DERP
and Wi-Fi sections above) versus **Decode errs** climbing on a clean
connection (a decoder problem — disconnect and reconnect, and check
Console.app for VideoToolbox errors). If you get all the way to the
stalled alert, reconnecting is the reliable reset.

## Remote control grant fails asking for Accessibility

Granting control the first time pops **"Accessibility Permission
Needed"**. This is expected: injecting mouse and keyboard events requires
the Accessibility permission, which is separate from Screen Recording.
Open **System Settings → Privacy & Security → Accessibility**, toggle
Tailscreen on, then grant control again — the grant is refused (not
queued) until the permission exists, so you do need to click Grant a
second time. If you launched Tailscreen from Terminal, the permission may
need to go to Terminal instead, same as with Screen Recording.

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

- macOS version (`sw_vers`).
- Mac model.
- Tailscale version on both peers, and whether the connection is `direct`
  or via DERP (`tailscale status`).
- Relevant Console.app log lines (filter for `Tailscreen`).

"It doesn't work" is hard to fix. The above is much easier.
