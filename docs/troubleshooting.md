---
title: Troubleshooting
nav_order: 7
permalink: /troubleshooting/
---

# Troubleshooting
{: .no_toc }

1. TOC
{:toc}

## "Permission Denied" when capturing screen

macOS hasn't granted Screen Recording access yet.

1. Open **System Settings → Privacy & Security → Screen Recording**.
2. Toggle **Tailscreen** (or your terminal app, if you launched it from a
   shell) on.
3. Quit and relaunch Tailscreen.

## "Connection Failed"

- Confirm both Macs are on the same tailnet — open the Tailscale menubar
  app on each and check that the other shows up.
- Confirm Tailscale itself is running and connected on both machines.
- Double-check the hostname or IP. **Show Tailscale Info** in the sharer's
  menu prints the values the viewer should use.
- Check your tailnet ACLs allow TCP+UDP/7447 from the viewer to the sharer.
  See [Privacy & Security → Access control]({% link security.md %}).

## Low FPS or stuttering

- Run `iperf3` between the two Macs to measure the actual end-to-end
  bandwidth — Wi-Fi reality is often a fraction of the negotiated link rate.
- Switch the sharing Mac (or both) to wired Ethernet. Wi-Fi power saving
  is a frequent cause of jitter spikes.
- Confirm Tailscale is using a direct connection rather than a DERP relay
  (`tailscale status` will show `relay "..."` for DERP, or `direct` for
  P2P). DERP adds latency.
- Reduce the captured display's resolution temporarily as an A/B test.

## Black screen or no video

1. Verify Screen Recording permission is granted (see above).
2. Restart both apps (sharer and viewer).
3. Open **Console.app**, filter for `Tailscreen`, and look for VideoToolbox
   or Metal errors.
4. If the viewer shows the toolbar but no frames at all, the keyframe-
   request path may be broken — try **Disconnect** then reconnect; that
   forces a fresh keyframe.

## Two local instances see no peers

Both processes are sharing one Tailscale state directory at
`~/Library/Application Support/Tailscreen/tailscale`, so they reuse the same
machine key and the browser is looking at its own node. Use
`./test-local.sh` (which sets `TAILSCREEN_INSTANCE` per child), or set
`TAILSCREEN_INSTANCE=1` / `TAILSCREEN_INSTANCE=2` manually so each instance
gets its own state directory and hostname.

See [Usage → Testing on one machine]({% link usage.md %}#testing-on-one-machine).

## Build fails with linker errors

You ran bare `swift build` instead of going through `make`. The Go build
emits `libtailscale.a`; without it nothing links. Run `make build` (or at
least `make tailscale`) once, then `swift build` will work for the rest of
that build tree.

## TailscaleKit submodule looks empty

After cloning the repo, run:

```bash
git submodule update --init --recursive
```

The `TailscaleKitPackage/upstream/libtailscale` submodule is pinned in
`.gitmodules` and required for the build.

## Reporting a bug

Please open an issue on
[GitHub Issues](https://github.com/middle-management/tailscreen/issues) with:

- macOS version (`sw_vers`).
- Mac model.
- Tailscale version on both peers, and whether the connection is
  `direct` or via DERP.
- Relevant console log lines (filter for `Tailscreen` in Console.app).
