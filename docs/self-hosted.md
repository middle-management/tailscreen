---
title: Self-hosted control planes
nav_order: 7
permalink: /self-hosted/
---

# Self-hosted control planes
{: .no_toc }

1. TOC
{:toc}

Tailscreen rides on Tailscale's tsnet, which speaks to a control plane to
exchange WireGuard keys. By default that control plane is
`controlplane.tailscale.com`. If you'd rather not depend on Tailscale Inc. —
because your org already runs [headscale](https://github.com/juanfont/headscale),
because you want a fully airgapped tailnet, or just because — Tailscreen
can point at any tsnet-compatible control plane via two environment
variables.

## Why you might want this

- You don't want to depend on a third-party SaaS for the key-exchange
  hop, even though it can't decrypt your traffic.
- Your organisation already operates headscale and you want Tailscreen to
  join the same tailnet.
- You're running on an isolated network where `controlplane.tailscale.com`
  isn't reachable.

## What's supported

Any tsnet-compatible control plane. Tailscreen's CI continuously verifies
against [headscale 0.26.1](https://github.com/juanfont/headscale)
(see [`e2e/docker-compose.yml`](https://github.com/middle-management/tailscreen/blob/main/e2e/docker-compose.yml)
and the connectivity test in
[`Tests/TailscreenTests/TailscaleConnectivityTests.swift`](https://github.com/middle-management/tailscreen/blob/main/Tests/TailscreenTests/TailscaleConnectivityTests.swift)).
Other control planes that implement the tsnet/Tailscale control protocol
should work — they're just not exercised by CI.

The video pipeline, peer discovery, annotation back-channel, and metadata
service are unchanged. The only thing the control-plane override touches
is where the ephemeral tsnet node fetches its keys.

## The two environment variables

| Variable                   | Purpose                                                                            |
| :------------------------- | :--------------------------------------------------------------------------------- |
| `TAILSCREEN_TS_CONTROL_URL`| Control-plane URL. Example: `http://headscale.internal:8080`. Unset → Tailscale.   |
| `TAILSCREEN_TS_AUTHKEY`    | Pre-shared auth key for unattended sign-in. Unset → interactive browser login.     |

Both fall back to the Tailscale defaults when unset, so if you don't set
them, nothing changes.

### Setting env vars for a GUI app on macOS

The catch: a GUI launch from Finder or Spotlight doesn't inherit your
shell environment, so `export` in your `.zshrc` won't be visible to
`Tailscreen.app`. Three options that do work:

- **Run from a terminal:**
  ```bash
  TAILSCREEN_TS_CONTROL_URL=http://headscale.internal:8080 \
  TAILSCREEN_TS_AUTHKEY=hskey-... \
    open -a Tailscreen
  ```
- **`launchctl setenv`** (persists for the current login session):
  ```bash
  launchctl setenv TAILSCREEN_TS_CONTROL_URL http://headscale.internal:8080
  launchctl setenv TAILSCREEN_TS_AUTHKEY hskey-...
  open -a Tailscreen
  ```
- **A LaunchAgent plist** under `~/Library/LaunchAgents/` if you want the
  variables to outlive a logout. Standard `EnvironmentVariables` dict;
  the macOS `launchd.plist(5)` man page covers the format.

The auth key is a credential. Treat the LaunchAgent plist with the same
care you'd treat a stored password.

## Walked example: headscale

Anything below "your control plane is reachable from this Mac" is your
infrastructure team's job, not Tailscreen's, but here's a minimum viable
recipe to verify the Tailscreen side end-to-end.

### 1. A headscale instance

The simplest is the same Docker compose stack the test harness uses.
[`e2e/docker-compose.yml`](https://github.com/middle-management/tailscreen/blob/main/e2e/docker-compose.yml)
brings up headscale on `localhost:8080`. For a real deployment you'll
want headscale on a routable host, with TLS, and configured DERP — see
the [headscale docs](https://headscale.net/) for production guidance.

### 2. A user and a pre-auth key

```bash
headscale users create tailscreen
headscale --output json preauthkeys create \
    --user "$(headscale --output json users list | jq -r '.[] | select(.name=="tailscreen") | .id')" \
    --reusable --ephemeral
```

The `key` field of the resulting JSON is what you'll feed Tailscreen.

### 3. Point Tailscreen at it

```bash
TAILSCREEN_TS_CONTROL_URL=https://headscale.example.com \
TAILSCREEN_TS_AUTHKEY=hskey-... \
  open -a Tailscreen
```

The first share or connect spins up an ephemeral node against headscale.
You can confirm it landed by tailing headscale's logs and watching for a
new `tailscreen-...` machine join.

## Caveats

- **Interactive login expects a browser-redirect endpoint.** Tailscale's
  hosted control plane and headscale both implement it; if you're on a
  control plane that doesn't, set `TAILSCREEN_TS_AUTHKEY` so the node can
  come up unattended.
- **DERP relays default to Tailscale's.** If your direct WireGuard
  connections work (they usually do), DERP never enters the picture. If
  they don't and you'd rather not relay through Tailscale-operated DERPs,
  configure your control plane with its own DERP map. Tailscreen picks up
  whatever the control plane hands it.
- **Ephemeral nodes still work.** "Stop Sharing" / "Disconnect" tears the
  node down on the control plane just like it does against
  `controlplane.tailscale.com`.
- **ACLs are still your access-control plane.** All the guidance in
  [Privacy & Security]({% link security.md %}#access-control) about TCP
  and UDP port 7447 applies — just enforce it via your control plane's
  ACL system instead of Tailscale's.
