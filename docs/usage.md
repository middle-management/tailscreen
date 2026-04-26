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

1. Create a free [Tailscale account](https://tailscale.com/) if you don't
   already have one.
2. Both the sharing computer and the viewing computer need to be on the same
   tailnet.
3. Install Tailscreen on each Mac — see [Install]({% link install.md %}).

You don't need to add Tailscreen as a regular Tailscale device — it spins up
its own ephemeral tsnet node each time you start sharing or connecting, and
the node is cleaned up automatically afterwards.

## Sharing your screen

1. Click the Tailscreen icon (📺) in the menubar.
2. Select **Start Sharing**.
3. Grant Screen Recording permission if prompted.
4. Tailscale will connect automatically (ephemeral node, auto-cleanup).
5. Pick **Show Tailscale Info** to see the hostname and Tailscale IP your
   peers should connect to.

The first time you share, you'll be sent through Tailscale's browser-based
login (or you can pre-set `TAILSCREEN_TS_AUTHKEY`; see
[Contributing → Auth keys]({% link contributing.md %})).

## Viewing a shared screen

### Option 1 — Browse Shares (easiest)

1. Click the Tailscreen icon (📺) in the menubar.
2. Select **Browse Shares...**.
3. Tailscreen scans your tailnet and lists discovered shares.
4. Click **Connect** next to the share you want.
5. A viewer window opens.

### Option 2 — Manual connection

1. Click the Tailscreen icon (📺) in the menubar.
2. Select **Connect to...**.
3. Enter the Tailscale hostname or IP (e.g. `macbook-pro` or `100.x.x.x`).
4. A viewer window opens.

## Annotations

While viewing a shared screen, the toolbar exposes drawing tools so you can
mark up the sharer's display. Strokes are sent over a reliable TCP back-channel
(see [Network Protocol]({% link protocol.md %})) and rendered on the
sharer's machine in a transparent overlay window.

## Stopping

- **Stop sharing** — pick **Stop Sharing** from the menubar.
- **Stop viewing** — pick **Disconnect**, or close the viewer window.

Tailscale ephemeral nodes are torn down automatically — there is nothing to
clean up in the Tailscale admin console.

## Testing on one machine

You can exercise the full peer-discovery and connection paths on a single Mac
using the bundled launcher script:

```bash
./test-local.sh        # 2 instances (default)
./test-local.sh 3      # N instances
```

Each child process gets `TAILSCREEN_INSTANCE=<i>`, which suffixes the
Tailscale state directory and hostname (e.g. `wisp-1`, `wisp-2`) so the
processes register as distinct tailnet nodes. Without this, two processes
would share `~/Library/Application Support/Tailscreen/tailscale`, reuse the
same machine key, and the browser would see zero peers — it would be looking
at its own node.

Merged stdout/stderr lands in `/tmp/tailscreen-merged.log` (override with
`TAILSCREEN_LOG`). Ctrl-C kills the whole process group.

This tests Tailscale integration and peer discovery, but does **not**
exercise NAT traversal — both processes share one network stack.

## Performance tips

- Tailscale will prefer a direct peer-to-peer connection when possible;
  direct connections give LAN-like performance even over the internet.
- Wired Ethernet > Wi-Fi for the most consistent latency.
- Disable Wi-Fi power saving on both machines.
- Close bandwidth-hungry apps on the sharer (cloud sync, large uploads).
- Check Tailscale status to confirm a direct connection rather than a DERP
  relay.
