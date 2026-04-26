---
title: Usage
nav_order: 3
permalink: /usage/
---

# Usage
{: .no_toc }

1. TOC
{:toc}

## First-time setup

You need a Tailscale account. The free personal tier is fine — it's not a
trial, it doesn't expire. Sign up at [tailscale.com](https://tailscale.com/),
install the Tailscale app on every Mac you want to share between, and let it
add them to your tailnet. Then install Tailscreen on those Macs (see
[Install]({% link install.md %})) and you're done.

You do **not** need to register Tailscreen as a Tailscale device. It spins
up its own ephemeral tsnet node when you start sharing or connecting, and
Tailscale removes the node automatically when you stop. Your admin console
stays clean.

## Sharing your screen

1. Click the 📺 in the menubar.
2. Pick **Start Sharing**.
3. Approve Screen Recording if macOS asks. (See
   [Install → Permissions]({% link install.md %}#permissions) — the
   permission only takes effect after a relaunch.)
4. The first time you ever share, Tailscale will open a browser tab to log
   you in. After that it's a one-click affair.
5. Pick **Show Tailscale Info** if you want to read off the hostname or
   100.x.x.x address to whoever's connecting.

That's the whole sharing flow. There's no "create a meeting", no
"copy link". The screen is up. People who can reach your machine on your
tailnet can see it.

## Viewing a shared screen

You have two options. The first is what you actually want.

### The good one: Browse Shares

1. Click the 📺 in the menubar.
2. Pick **Browse Shares...**.
3. Tailscreen probes your tailnet, asks every machine "are you sharing?",
   and shows you the ones that said yes.
4. Click **Connect** next to the share you want.

A window opens. You're done.

### The other one: Connect to...

For when you already know the hostname or IP and don't want to wait for
discovery to finish.

1. Click the 📺 in the menubar.
2. Pick **Connect to...**.
3. Type the Tailscale hostname (`macbook-pro`) or IP (`100.x.x.x`).

Same window opens.

## Annotations

The viewer's toolbar has drawing tools. Doodle on the sharer's screen and
your strokes appear in a transparent overlay window on their Mac. The
back-channel rides over TCP rather than the lossy UDP video stream — see
[Network Protocol]({% link protocol.md %}) — so individual stroke segments
won't drop even if you lose a video frame or two.

Annotations are not persisted on either end. Quit the viewer or hit "Stop
Sharing" and they're gone.

## Stopping

- Sharer side: **Stop Sharing** in the menu, or quit the app.
- Viewer side: **Disconnect** in the menu, or close the window.

Either way, the ephemeral tsnet nodes get torn down. Nothing to clean up.

## Testing on one Mac

You can run the full peer-discovery + connection path on a single machine
using the bundled launcher:

```bash
./test-local.sh        # 2 instances
./test-local.sh 3      # N instances
```

Each child gets `TAILSCREEN_INSTANCE=<i>`, which is a small but critical
detail: it suffixes the Tailscale state directory and hostname (so you get
`wisp-1`, `wisp-2`, etc.) and the processes register as different tailnet
nodes.

If you skip this and just launch the binary twice, both processes will
share `~/Library/Application Support/Tailscreen/tailscale`, both will use
the same machine key, the tailnet will think they're the same device, and
**Browse Shares** will return zero results — because each instance is
looking at its own node and excluding it. This is the single most common
"why doesn't this work" report. It always turns out to be this.

Logs from all children are merged into `/tmp/tailscreen-merged.log`
(`TAILSCREEN_LOG=...` to override). Ctrl-C kills the whole process group.

This setup tests Tailscale integration and peer discovery, but it does
**not** test NAT traversal — both processes share the same network stack.
For that, you need two actual machines.

## Performance: getting it to feel snappy

Tailscale will try really hard to give you a direct WireGuard connection.
When that works, latency is essentially the round-trip time between the two
machines and not much more. When it doesn't work and falls back to a DERP
relay, you'll feel it.

Things you can do:

- **Wired Ethernet on at least one end.** Wi-Fi is the largest source of
  jitter in any well-engineered video pipeline. Tailscreen is no exception.
- **Disable Wi-Fi power saving.** macOS will happily park the radio between
  packets to save battery, which murders interactive latency.
- **Check `tailscale status`.** If it says `relay "..."`, you're going
  through DERP. Direct connections show as `direct`. If you're stuck on
  DERP, it's almost always a NAT or firewall issue on one side, not
  Tailscale.
- **Don't run a 10 GB cloud sync at the same time.** This is more of a
  "don't punch yourself in the face" tip but it shows up.
