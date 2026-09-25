# Default-on viewer consent, persistent per-peer allow/deny list, and a finished accept/decline handshake

> Status: **shipped**, including a follow-up security-review pass. One
> documented known limitation remains (see below).

## Problem it solved

Viewer approval defaulted **off** (`ViewerApprovalDefaults.load()` returned
`false` when unset), so anyone on the tailnet could join a share instantly
with no memory of past decisions, and request-to-share was one-way
(`.acceptShare`/`.declineShare` were unused Codable scaffolding — a requester
never learned whether the other side even saw the request).

## What shipped

- Approval defaults **on** for anyone who never touched the toggle
  (`object(forKey:) as? Bool ?? true` — free migration: an explicit past
  choice is still honored). `TAILSCREEN_OPEN_DOOR=1` escape for
  `test-local.sh`/harness runs that assume open-door joins.
- Persistent per-peer **allow/deny** keyed by StableNodeID (`ViewerAccessPolicy.swift`
  → `ViewerAccessPolicyStore`), with a Settings "Remembered viewers" list.
- A pure `admissionDecision(policy:requireApproval:) -> Admission` function
  (`.admit`/`.park`/`.reject`), CI-tested, mirroring the existing
  `audioRelayDecision` pattern.
- Finished accept/decline round trip: new TCP message `shareResponse = 0x05`,
  reused as reply on the **same connection** the request arrived on (never a
  dial-back to a claimed hostname); new UDP control byte `helloDenied = 0x08`
  so a declined viewer sees "The sharer declined" instead of a generic
  teardown.

## Key decisions and why

- **Identity = StableNodeID (`PeerStatus.ID` via LocalAPI), never IP or
  hostname.** IPs of ephemeral nodes get recycled, hostnames change on
  rename, node keys rotate on re-auth — StableNodeID is the one identifier
  that survives all of these. Display name is refreshed on each sighting.
- **UDP source address is trustworthy identity within a tailnet.** tsnet's
  netstack only delivers packets that arrived over a WireGuard tunnel
  negotiated against a netmap-authenticated peer, so a peer can't forge
  another peer's 100.x address. Wire *payload claims* (e.g. `fromHostname`)
  are never used for policy — only for display. This same argument is what
  `plans/share-by-token.md` reuses verbatim for guest-tunnel addresses.
  Unresolvable peer (absent from netmap) is treated as unknown → parked,
  never auto-allowed.
- **Deny outranks the open-door gate everywhere, not just for pending
  viewers** (the original plan only covered the parked case). A remembered
  deny rejects synchronously on re-HELLO even with the gate off, and a
  blocked peer that slipped into the fan-out before its async resolution
  finished gets expelled once it resolves. Without this, "Deny & Block" would
  be a no-op the moment the sharer turned the approval gate off.
- **The TCP annotation/control channel needed its own admission check —
  found in security review, not the original design.** The UDP HELLO path
  was gated but the TCP channel accepted ops from anyone who could dial 7447.
  Fixed by threading each connection's `remoteAddress` through and checking
  it against the admitted-viewer set on every op; `expelViewer` was made
  symmetric (also drops video tails and closes the peer's TCP connection).
- **Accepting a request-to-share pre-approves the requester's IP** — a
  one-time pre-approval so the accept doesn't produce a second consent
  prompt from the same person seconds later; never overrides a remembered
  deny.
- **Bounded resources against a hostile/flaky peer**: `pendingViewers` capped
  at 32, `pendingRequests` capped at 16 and deduped by **source IP** (never
  the spoofable wire-claimed hostname — a hostname-varying flood could
  otherwise stack unbounded rows and pin unbounded 120 s connections).
- **A parked (awaiting-approval) viewer must not self-disconnect** — the
  client suppresses its 15 s receive-idle timeout while `awaitingApproval`,
  since default-on approval makes "waiting for a human" the common case, not
  the exception.

## Rejected / narrower-than-planned alternatives

- Notification-action buttons (Accept from the banner) — dev builds can't
  post notifications at all; the popover stays the only accept surface.
- Auto-connecting the requester on accept — feedback only; auto-connect
  deferred as a follow-up (never picked up).
- Cross-device sync of the allow/deny list — per-Mac `UserDefaults` was
  judged sufficient.

## Where it lives now

- Policy store + pure decision: `Sources/ViewerAccessPolicy.swift`
  (`PeerPolicy`, `PeerAccessEntry`, `ViewerAccessPolicyStore`,
  `admissionDecision`) — now in the portable tier per
  `plans/platform-alignment.md` Phase 2.1 (`TailscreenProtocol/ViewerAccessPolicy.swift`).
- Server: `TailscaleScreenShareServer.swift` (`accessPolicies` lock,
  `setAccessPolicies`, `isAdmittedViewerIP`, `expelViewer`,
  `connectedDenyList`, `canAcceptPending`).
- Protocol: `ScreenShareProtocol.swift` (`shareResponse = 0x05`),
  `RTPPacket.swift` (`helloDenied = 0x08`).
- Client: `TailscaleScreenShareClient.swift` (`onDeniedBySharer`,
  `awaitingApproval` suppression).
- UI: `MenuBarView.swift` (`PendingViewersList` split Accept/Deny via
  `Menu(primaryAction:)`), `SettingsView.swift` (remembered-viewers list).
- Cross-platform generalization (`ViewerRosterDecision`, `HubViewerRow`) is
  `plans/platform-alignment.md` Phase 2.2/2.3.
- Referenced from `plans/remote-control.md` as the prerequisite for the
  control-grant identity (must be an approved, allow-list-identified viewer,
  not just `ip:port`, before a grant can be pinned).

## Known limitation

`peerStableIDCache` freezes IP→StableNodeID for the life of the share;
ephemeral-IP reuse mid-share (rare) could theoretically let a new peer
inherit a cached identity. Documented in a code comment; a short TTL would
close it if it's ever observed in practice. Not fixed — low likelihood, no
report of it happening.
