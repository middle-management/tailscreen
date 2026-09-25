# Share by token — no-sign-in sharing, end to end

> Status: **shipped**, all phases, all three apps (sharer + viewer, signed-in
> and signed-out). Groundwork/feasibility: `plans/tailcat-evaluation.md`.
> Remaining gaps are listed under "Known deviations" below; nothing here is
> blocking.

## What it is

A sharer clicks **Share via Link**, gets a short token (also a `tailscreen:`
URL), and hands it to anyone — no Tailscale account, no tailnet membership.
A viewer pastes the token or clicks the link, lands in the same
pending-approval flow as tailnet viewers, and gets the same RTP stream,
annotations, and (if granted) remote control. Stopping the share kills the
token forever. On macOS a share can run **link-only**, with no sign-in and no
tsnet node at all.

Underneath: a WireGuard tunnel bootstrapped over DERP with NAT hole-punching
(Tailscale's data plane without its control plane — the mechanism
`plans/tailcat-evaluation.md` proved out), carried by the same libtailscale
archive, speaking the **unmodified 7447 wire protocol** inside the tunnel.

## Goals / non-goals

Goals: token share alongside (not instead of) the normal tailnet share;
existing viewer UI on every platform; zero 7447 wire changes; **approval is
mandatory for guests regardless of the "Require approval" toggle**, with
identity = the guest's WireGuard node key (cryptographic, not claimed).

Non-goals (v1, still true): browser viewer (separate plan,
`plans/browser-viewer.md`); guest *sharers* (tokens let people watch/control,
not share their own screen); voice/system audio to guests (PT98/99 fan-out
works mechanically but consent/mixing UX for guest mics is a separate piece);
persistent/reusable tokens (v1 tokens are ephemeral, one per share); tailnet↔guest
bridging of any kind (a guest sees only the share fan-out — the packet filter
admits 7447 + the control port to the server's own address, nothing else).

## Key design decisions and why

- **Fork `tailscale/libtailscale` rather than patch it.** The guest backend's
  Go dependencies can't be expressed as a `Patches/*.patch` (generated
  lockfile content), and two Go c-archives can't share one binary — so the
  guest package has to live inside the *same* archive as tsnet. The old
  23-patch series became ordinary commits on `middle-management/libtailscale`
  (branch `tailscreen-main`); upstreamable ones continue as normal PRs against
  upstream from there. See `.claude/rules/tailscalekit.md` for the submodule
  mechanics.
- **Zero wire changes.** The token is transport-plane only, parsed solely by
  the vendored Go (CBOR, field names pinned by a vendored test); Swift treats
  it as an opaque string. `docs/spec.md` Appendix D documents the bootstrap as
  informative scope — no new registry rows, no vectors.
- **Guest identity is the node key, not a claim.** Viewer identity became
  `ViewerInfo`/`PendingViewerInfo.isGuest` + the guest node key from
  `GuestServerNode.peers()` (not the originally-planned `ViewerIdentity` enum
  — the addr-keyed rosters made a flag the smaller honest change). Guest
  addrs are derived from the node key (`tcAddrForKey`, 80 bits of key in
  `fd7a:115c:a1e0::/48`) and can't collide with tailnet addresses because
  they live in a separate netstack. `plans/viewer-consent-and-access-control.md`
  is the reasoning for why source-addr identity is trustworthy inside a
  WireGuard tunnel; it transfers verbatim here.
- **Eviction actually closes the tunnel.** tailcat's client map was
  append-only; `RemoveClient(nodekey)` was added (delete from map, rebuild
  netmap without the peer, push to magicsock, denylist the key against
  re-handshake) — closing the gap `plans/tailcat-evaluation.md` found. Deny on
  a guest calls SERVER_BYE *and* `guest_server_remove_peer`, stronger than the
  tailnet case where a denied peer just can't re-approve.
- **Remembered guest decisions are session-scoped, not persisted.** Ephemeral
  keys make "always allow" meaningless across shares, so the store simply
  drops `.guest` entries on share stop.
- **Full-address tokens (embedded DERP region), not short ones.** Viewers
  never need to fetch a DERP map. Public DERP is the default bootstrap; a
  settings/DERP-override exists for self-hosted relays, because public relays
  are rate-limited and not meant to sustain relayed video long-term
  (`docs/self-hosted.md` has the derper recipe).
- **The guest TCP control channel reuses the tailnet one's entire machinery**
  (`TailscreenControlListener.start(adopting:)`, `FramedControlChannel`) —
  same admitted-viewer gate, same single-grantee control gate, same
  annotation bookkeeping — rather than a parallel implementation. The guest C
  surface already had TCP fds bit-compatible with tsnet's, so this was
  adoption, not new protocol.
- **Sharer-side guest mode on Linux/Windows follows `plans/platform-alignment.md`'s
  rule**: approve/deny/drop must exist wherever guests can exist, so it rode
  with the sharer port rather than landing later. `SharerLinkSession`
  (TailscreenSharer, an actor) is the one lifecycle both host engines
  (`LinuxShareSession`, `WindowsShareSession`) drive, so the enable → attach
  listener → token → rotate → evict → teardown sequence is written once.
- **Link-only sharing needed a signed-out picker phase, not just a toggle.**
  The GTK app previously always brought a tsnet node up on launch; a
  never-signed-in person hit "Waiting for login…" with no other path visible.
  `HubSignInPane` (shared, TailscreenHubUI) now offers **Your tailnet** and
  **A share link** side by side, driven by one portable decision
  (`WelcomePaneDecision.linkShareAction`), and all three hosts read the same
  function — macOS's own welcome pane included.

## Rejected alternatives worth remembering

- A `Destination`/`ViewerIdentity` enum for guest vs tailnet, everywhere —
  rejected in favor of a flag + node key, twice (server roster, viewer
  `ViewerConfig.guestToken`), because the existing addr-keyed types made the
  flag the smaller, more honest diff both times.
- Upstreaming everything before building on it — rejected; upstream
  libtailscale is near-dormant, so blocking on it would have stalled the
  whole feature for no benefit. Continued upstreaming happens in parallel.

## Where it lives now

- Fork: `middle-management/libtailscale`, branch `tailscreen-main`, `guest/`
  package (vendored from tailcat `c04c5af`, BSD-3) + `guestnode.c` C exports
  (`guest_server_*`, `guest_client_*`).
- Swift wrapper: `Packages/TailscaleKit/Sources/GuestNode.swift`
  (`GuestServerNode`/`GuestClientNode`), vending ordinary
  `PacketListener`/`Listener`/`IncomingConnection` types (guest fds are
  bit-compatible with tsnet's).
- Sharer core: `TailscaleScreenShareServer` dual-listener routing (guest +
  tailnet), `SharerDecisions` guest-approval rule, `SharerLinkSession`.
- Viewer core: `TsnetTransport`/`GuestTransport` (portable hosts),
  `TailscaleScreenShareClient.connectGuest` (macOS); shared session core is
  `runSession`.
- Token/link format: `ShareLinkFormat` (TailscreenProtocol), pinned by
  `ShareLinkFormatTests`.
- UI: macOS `SharingCard`/menubar Share-via-Link section, Settings → Link
  sharing; shared `HubJoinCard`, `HubLinkSharing`, `HubGuestChip`, `HubSignInPane`
  (TailscreenHubUI) for Linux/Windows.
- Docs: `docs/usage.md` "Sharing via link (guests)", `docs/security.md`
  guest sections, `docs/self-hosted.md` derper recipe, `docs/spec.md`
  Appendix D, `docs/platform-support.md` matrix rows.

## Known deviations / remaining gaps

- Guest naming in notifications (macOS) and roster rows (Linux/Windows)
  falls back to the tunnel IP, not the key fingerprint — fingerprint polish
  never landed.
- Per-guest relay/direct indicator (the risk-section stretch item) deferred.
- `Settings → Link sharing` (feature on/off, DERP override) is macOS-only;
  Linux/Windows have no off-switch for the feature.
- `tailscreen:` scheme registration: AppImage registers only after desktop
  integration; the Windows zip build (unpackaged) registers nothing (MSIX
  does). Both noted in the platform matrix.
- No single-instance redirection for a scheme-handler launch — each click
  starts a new process; `ProtocolActivation.observe` is the wire a future
  redirect would use.

## Risks (still relevant)

- **Relayed guests on public DERP**: mitigated by the per-guest relay
  indicator (deferred, see above) and pushing self-hosted derper in docs; no
  hard cap shipped.
- **Tunnel MTU (1360) vs RTP packetization** (`DatagramInbox` targets ≤1200 B
  payloads) — verified fine in the Phase 1 spike, no clamp needed.
- **Token leakage**: bounded by mandatory approval, ephemeral keys, and
  tunnel-level denylist on deny; New Link rotates instantly.
