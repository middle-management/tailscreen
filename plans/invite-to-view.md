# Invite to view — "ask Fredrik to join my share"

> Status: **proposed**, nothing built. The mirror image of Ask to Share
> (spec §13.1): there a would-be viewer asks a peer to share; here a sharer
> asks a peer to watch.

## What it is

While sharing, the sharer picks a peer from the hub's peer list and clicks
**Invite**. On the peer's machine a notice appears: "Robert invites you to
view their screen" with **Join** / **Decline**. Join opens a viewer on that
share and admits it without a second approval prompt; Decline (or no answer
in 120 s) shows on the sharer's row as declined / no reply.

## Why it's cheap

Almost every piece exists, pointed the other way:

- **The invitee is already listening.** All three hosts keep a long-lived
  `TailscreenControlListener` for Ask to Share (`SharerAskToShareCoordinator`),
  independent of whether they share. The invite lands on that listener.
- **Request/answer on one TCP connection** is the Ask to Share shape
  (TS-MET-001..006): sender holds the connection open, the answer rides it
  back, no dial-back. `TailscreenRequestToShareClient` + `ShareRequestInbox`
  are the templates for the client and the coalescing/expiry inbox.
- **Pre-approval** exists: `TailscaleScreenShareServer.preApproveViewer(ip:)`,
  consumed on the next HELLO from that IP.
- Old peers drop unknown TCP type bytes, so an invite to an old build reads
  as "no reply", the same as TS-MET-003.

## Wire change (one commit, four places)

- New TCP framed type **`0x0F inviteToView`**, sharer → peer, payload
  `InviteToViewPayload` `{"fromHostname": "...", "sharerIP": "..."}`.
  The spec uses `fromHostname` only for display; the invitee connects to the
  **source address of the invite connection**, never to a claimed IP (same
  rule as TS-MET-004). `sharerIP` could then be dropped entirely; keep the
  payload minimal unless a guest-tunnel case needs it.
- Answer reuses **`0x05 shareResponse`** with two new `TailscreenRequest`
  types, `acceptInvite` / `declineInvite`. This keeps the type-byte budget
  and the client's read loop unchanged. (Alternative: new `0x10`. Prefer
  reuse unless conformance shows the type-string enum is closed.)
- Spec: new §13.3 with TS-MET-02x requirements mirroring 001–006 (hold the
  connection, answer on it, timeout = no answer, dedupe by source address,
  bound pending invites, never auto-join).
- `WireByteRegistryTests` TCP table, spec appendix, conformance vector for
  `0x0F` encode/decode and the two new response strings, `sdk/go` support.

## Admission: the one real design question

The sharer dials the invitee's **main node** IP, but a viewer may connect
from a different address — notably an ephemeral `tailscreen-client-` node.
Pre-approving the invite's destination IP then misses, and the invitee hits
the normal approval prompt (harmless, just one extra click). Options, in
order of preference:

1. **Pre-approve by StableNodeID/user of the invited node, consumed once,
   expiring ~60 s after accept.** Needs `SharerAccessCoordinator`'s
   LocalAPI WhoIs lookup at HELLO time; matches the user, not the node, so it
   covers ephemeral client nodes owned by the same login. Verify ephemeral
   nodes resolve to the inviter's user before relying on it.
2. Pre-approve the IP only and accept the extra prompt when the invitee
   views from another node. Simplest; ship this first if (1) stalls.

Never: auto-admit on a token carried in HELLO (needs a HELLO wire change and
re-opens the open-door problem), or auto-join on the invitee's side
(a sharer must not be able to open a window on someone's machine without a
click — same reasoning as TS-LNK-010).

Guests (share-by-token) are out of scope: they have no tailnet identity to
invite. The invite is tailnet-only.

## Per-platform work

- **TailscreenKit**: `InviteToViewClient` (sharer side, mirrors
  `TailscreenRequestToShareClient`, returns accepted/declined/noReply);
  `InviteInbox` + an `onInviteReceived` handler on `TailscreenControlListener`;
  a small `@MainActor` coordinator on the invitee side shared by all hosts
  (accept → answer on the connection, then call the host's "connect to
  `sourceIP`" closure). Tests beside `SharerAskToShareCoordinatorTests`.
- **macOS**: Invite button on peer rows in the hub (only while sharing,
  disabled for `tailscreen-client-` nodes and peers already viewing); invite
  state on the row; incoming invite as a notification + in-hub banner with
  Join/Decline.
- **Linux / Windows**: same in `TailscreenHubUI` (`HubScreenList` peer row,
  `HubCards` banner), so both get it from one place.
- **L10n**: new keys in `TailscreenL10n`; `make test-l10n`.
- **Diagnostics**: `invite.sent`, `invite.answered`, `invite.received` —
  new names go in the never-rename registry.
- **Docs**: `usage.md` section, `docs/spec.md` §13.3, `platform-support.md`
  if any platform lags.

## Order

1. Wire + spec + vectors + Go SDK + registry (lands alone, nothing calls it).
2. Portable client/inbox/coordinator + tests.
3. macOS UI, then the shared hub UI for Linux/Windows.
4. Admission option 1, if verified.
