---
title: Self-hosted control planes
nav_order: 8
permalink: /self-hosted/
---

# Self-hosted control planes
{: .no_toc }

1. TOC
{:toc}

Tailscreen rides on Tailscale's tsnet, which speaks to a control plane to
exchange WireGuard keys. By default that's `controlplane.tailscale.com`.
If you'd rather not depend on Tailscale Inc. — your org runs
[headscale](https://github.com/juanfont/headscale), you want a fully
airgapped tailnet, or just because — Tailscreen can point at any
tsnet-compatible control plane via two environment variables.

## What's supported

Any tsnet-compatible control plane. CI continuously verifies against
[headscale](https://github.com/juanfont/headscale) (the end-to-end test
boots a local headscale via Docker Compose, mints an ephemeral pre-auth
key, and runs the full connectivity test against it). Other control
planes implementing the tsnet/Tailscale control protocol should work —
they're just not exercised by CI.

The video pipeline, peer discovery, annotation back-channel and metadata
service are unchanged. The override only affects where the ephemeral
tsnet node fetches its keys.

## The two environment variables

| Variable                   | Purpose                                                                            |
| :------------------------- | :--------------------------------------------------------------------------------- |
| `TAILSCREEN_TS_CONTROL_URL`| Control-plane URL. Example: `http://headscale.internal:8080`. Unset → Tailscale.   |
| `TAILSCREEN_TS_AUTHKEY`    | Pre-shared auth key for unattended sign-in. Unset → interactive browser login.     |

Both fall back to the Tailscale defaults — leave them unset and nothing
changes.

### Setting env vars for a GUI app on macOS

A GUI launch from Finder or Spotlight doesn't inherit your shell
environment, so `export` in `.zshrc` won't reach `Tailscreen.app`. Three
options that work:

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
- **A LaunchAgent plist** under `~/Library/LaunchAgents/` to outlive a
  logout — standard `EnvironmentVariables` dict; see the macOS
  `launchd.plist(5)` man page for the format.

The auth key is a credential — treat the LaunchAgent plist like a stored
password.

## Walked example: headscale

Getting a control plane reachable from your machine is your
infrastructure team's job, not Tailscreen's — but here's a minimum viable
recipe to verify the Tailscreen side end-to-end.

### 1. A headscale instance

The simplest is the same Docker compose stack the test harness uses.
[`e2e/docker-compose.yml`](https://github.com/middle-management/tailscreen/blob/main/e2e/docker-compose.yml)
brings up headscale on `localhost:8080`. For a real deployment you'll
want headscale on a routable host, with TLS and configured DERP — see the
[headscale docs](https://headscale.net/) for production guidance.

### 2. A user and a pre-auth key

```bash
headscale users create tailscreen
headscale --output json preauthkeys create \
    --user "$(headscale --output json users list | jq -r '.[] | select(.name=="tailscreen") | .id')" \
    --reusable --ephemeral
```

The `key` field of the resulting JSON is what you feed Tailscreen.

### 3. Point Tailscreen at it

```bash
TAILSCREEN_TS_CONTROL_URL=https://headscale.example.com \
TAILSCREEN_TS_AUTHKEY=hskey-... \
  open -a Tailscreen
```

The first share or connect spins up an ephemeral node against headscale.
Confirm it landed by tailing headscale's logs and watching for a new
`tailscreen-...` machine join.

## Your own relay for share links (derper)

[Share via Link]({{ site.baseurl }}{% link usage.md %}#sharing-via-link-guests)
guests don't use a control plane — the link itself carries the crypto —
but they do bootstrap through a **DERP relay**: the sharer waits there,
the guest's first packets arrive there, and the connection then upgrades
to a direct path when NAT allows (staying relayed when it doesn't). By
default that's Tailscale's public relay network.

To keep guest traffic on infrastructure you run:

1. Run Tailscale's relay server,
   [`derper`](https://pkg.go.dev/tailscale.com/cmd/derper), on a machine
   both ends can reach, with a real hostname and TLS
   (`derper -hostname derp.example.com`).
2. Serve a DERP map describing it — a JSON document in Tailscale's
   [`tailcfg.DERPMap`](https://pkg.go.dev/tailscale.com/tailcfg#DERPMap)
   shape with one region pointing at your derper — from any URL you
   control.
3. Put that URL in **Settings → Link sharing → Relay override** on the
   sharing Mac. It applies to the next link you create.

Guests need no configuration: the token embeds the relay details, so a
link minted against your derper carries your derper. The relay sees only
ciphertext either way — self-hosting it is about availability and
traffic policy, not confidentiality.

Two things change when guests are **browsers** (the web form of the
link). A browser can only reach a relay over the DERP protocol's
WebSocket upgrade (`wss://`, which `derper` serves on its normal TLS
port), and it holds the browser's certificate rules: the derper needs a
certificate the browser already trusts — a self-signed one fails
silently, since a page can't ask you to accept it. And a browser can't
hole-punch, so a browser viewer never leaves the relay: budget the derper
for the share's bitrate times the number of browser viewers, for the
whole session, where a native guest usually costs it a few seconds of
bootstrap.

## Caveats

- **Interactive login expects a browser-redirect endpoint.** Tailscale's
  hosted control plane and headscale both implement it; on a control
  plane that doesn't, set `TAILSCREEN_TS_AUTHKEY` so the node can come up
  unattended.
- **DERP relays default to Tailscale's.** If your direct WireGuard
  connections work (they usually do), DERP never enters the picture. If
  they don't and you'd rather not relay through Tailscale-operated DERPs,
  configure your control plane with its own DERP map — Tailscreen picks
  up whatever the control plane hands it.
- **Ephemeral nodes still work.** "Stop Sharing" / "Disconnect" tears the
  node down on the control plane just as it does against
  `controlplane.tailscale.com`.
- **ACLs are still your access-control plane.** All the guidance in
  [Privacy & Security]({{ site.baseurl }}{% link security.md %}#access-control) about TCP
  and UDP port 7447 applies — just enforce it via your control plane's
  ACL system instead of Tailscale's.
</content>
