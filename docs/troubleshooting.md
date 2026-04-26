---
title: Troubleshooting
nav_order: 7
permalink: /troubleshooting/
---

# Troubleshooting
{: .no_toc }

1. TOC
{:toc}

If something's broken, it's almost certainly one of the things on this
page. We'll start with the boring permission stuff and work up to the
interesting failure modes.

## "Permission Denied" when capturing screen

You haven't granted Screen Recording yet, or you granted it and didn't
relaunch.

1. **System Settings → Privacy & Security → Screen Recording.**
2. Toggle **Tailscreen** on. (If you launched it from Terminal, you may
   need to toggle Terminal on instead — macOS attaches the permission to
   the launching process.)
3. **Quit Tailscreen completely and relaunch it.** macOS does not push the
   new permission to a running process. This is a macOS rule. We've tried
   to find a way around it. There isn't one.

## "Connection Failed"

Walk this checklist in order:

1. Open the Tailscale menubar app on both Macs and confirm they're both
   showing each other in the device list. If they're not both green, this
   is a Tailscale problem first, a Tailscreen problem second.
2. Confirm the hostname or IP. **Show Tailscale Info** in the sharer's
   menu prints exactly what the viewer should type.
3. Check your tailnet ACLs allow TCP **and** UDP on port 7447 from the
   viewer to the sharer. The default Tailscale ACL is "everything to
   everything" and will work fine. If you've tightened ACLs and forgot
   to allow 7447, that's your problem.
4. Try `tailscale ping <viewer-hostname>` from the sharer's command line.
   If that doesn't work, neither will Tailscreen — the issue is below
   us.

## Two local instances see no peers

This is the single most common "this doesn't work" report. It's always
this:

> Both instances are using the same Tailscale state directory at
> `~/Library/Application Support/Tailscreen/tailscale`. They both end up
> with the same machine key. The tailnet thinks they're the same device.
> **Browse Shares** excludes the device it's running on, so each instance
> sees an empty list.

Fix: use `./test-local.sh` (which sets `TAILSCREEN_INSTANCE` per child),
or set it manually:

```bash
TAILSCREEN_INSTANCE=1 .build/debug/Tailscreen
TAILSCREEN_INSTANCE=2 .build/debug/Tailscreen
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
- If the result is bad: switch one or both ends to wired Ethernet. This is
  the single biggest fix.
- If the result is good and the video is still bad: open Console.app,
  filter for `Tailscreen`, and look for VideoToolbox errors. Encoder
  starvation or decoder backpressure produces logs.
- Disable Wi-Fi power saving on both ends.

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

`TailscaleKitPackage/upstream/libtailscale` is pinned in `.gitmodules` and
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
