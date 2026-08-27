# Share by token — no-sign-in sharing, end to end

> Status: plan. Groundwork and feasibility evidence: `plans/tailcat-evaluation.md`
> (the control-plane-free tunnel is proven working on `tailscale.com v1.102.3`;
> the libtailscale bump is validated on the Go side; one token serves N
> individually-keyed viewers). This document is the build order: backend, core,
> UI, docs, in landable phases with gates.

## What ships

A sharer clicks **Share via Link**, gets a short token (also rendered as a
`tailscreen:` URL), and hands it to anyone — no Tailscale account, no tailnet
membership, no admin rights on the viewer's machine. A viewer pastes the token
into **Join a Share…** in the hub (or clicks the link) and lands in the same
approval flow tailnet viewers go through today: the sharer sees a pending row,
approves, and the viewer gets the same low-latency RTP stream, annotations,
and (if granted) remote control. Stopping the share kills the token forever.

Underneath: a WireGuard tunnel bootstrapped over DERP with NAT hole-punching —
Tailscale's data plane without its control plane, the mechanism tailcat
demonstrates — carried by the same libtailscale archive we already ship, and
speaking the unmodified 7447 wire protocol inside the tunnel.

## Goals

1. **Sharer**: start/stop a token share alongside (not instead of) the normal
   tailnet share; copy the token/link; see guest viewers in the existing
   roster; approve, deny, and drop them with the existing controls.
2. **Viewer**: join by pasted token or clicked link, on every platform with a
   viewer, through the existing viewer UI (placards, toolbar, stats).
3. **Same protocol**: zero changes to the 7447 wire protocol. RTP/UDP media,
   framed-TCP control, FEC/NACK/PLI — all identical inside the tunnel. No new
   wire bytes, so no registry/spec/vector churn in the media plane.
4. **Consent is stronger, not weaker, for guests**: approval is mandatory for
   token viewers regardless of the "Require approval" toggle, and identity is
   the viewer's WireGuard node key — cryptographic, not claimed.
5. The archive/patch-series problem gets solved on the way, because Phase 0
   forces it (see `plans/tailcat-evaluation.md`, "Who owns the archive").

## Non-goals (v1)

- Browser viewer (needs the reliable-transport profile; separate plan).
- Guest *sharers* — tokens let people watch/control your screen, not share
  theirs. Request-to-share over the guest channel is out.
- Voice/system audio to guests (PT 98/99 fan-out works mechanically, but mic
  capture consent copy and mixing UX for guests is its own piece; keep v1
  video + annotations + remote control).
- Persistent tokens ("my permanent share address", `genkey`-style saved keys).
  v1 tokens are ephemeral: one per share session, dead on stop.
- Cross-device sync of remembered guest decisions.
- tailnet↔guest bridging of any kind. A guest sees the share fan-out and
  nothing else; the packet filter admits only 7447 to the server's own
  address (plus the framed-TCP port), exactly as narrow as tailcat's
  `ServedTCPPorts` idea.

## Current state (what the feature builds on)

- **Sharer core**: `TailscaleScreenShareServer` (portable,
  `Packages/TailscreenKit/Sources/TailscreenSharer/`) — `start(...,
  existingNode:)` (`TailscaleScreenShareServer.swift:903-1005`) binds one
  `PacketListener` (UDP 7447) plus a shared `TailscreenControlListener`
  (framed TCP). Fan-out, pending/approve/deny (`SharerDecisions.swift:96-123`),
  one-time admit list keyed by peer IP (`:460-473`), SERVER_BYE denial.
- **Viewer identity**: keyed by UDP source addr, resolved to hostname +
  StableNodeID via LocalAPI; `plans/viewer-consent-and-access-control.md`
  documents why the source addr is trustworthy inside a WireGuard tunnel —
  an argument that transfers verbatim to the guest tunnel, where the addr is
  *derived from* the viewer's node key (`tcAddrForKey`: 80 bits of key in
  `fd7a:115c:a1e0::/48`).
- **Viewer core**: macOS `TailscaleScreenShareClient`; portable hosts use
  `TsnetTransport` + `ViewerConfig(hostname:port:...)`
  (`TailscreenViewerTsnet/TsnetTransport.swift:9-68`).
- **UDP-over-socketpair bridge**: patches 013–020 already solved "get a
  datagram across the C boundary" for tsnet (`[1B addr_len][addr][payload]`
  framing). The guest node reuses this mechanism unchanged.
- **Hub UI**: macOS `MainWindowView` (peer list, `connectToPeer`), menubar
  sharer tool (`MenuBarView`, `PendingViewersList` at `:560-596`);
  Linux/Windows share `TailscreenHubUI` (HubHeader/HubContent/HubViewerRoster).
  All strings via `L(_:)` in TailscreenL10n.
- **Proven** (see the evaluation doc): tailcat's e2e passes on v1.102.3 —
  DERP bootstrap → disco → direct-path upgrade → WG handshake → payload;
  libtailscale bumps to v1.102.3 with build/vet/test/c-archive green and our
  UDP exports intact; the wgengine seams (`SetPeerConfigFunc`,
  `SetPeerByIPPacketFunc`) are public interface methods there.

## Design

### Where the new Go lives — the forced move, made explicit

The guest backend is Go and must link into the **same** c-archive as tsnet
(two Go c-archives cannot share a binary — the `TailscreenDifferential`
lesson). Its dependencies (`tailscale.com@v1.102.3`) and its `go.mod` lines
cannot be expressed as a `Patches/*.patch` (generated lockfile content under
`patch -F0` — see "Where it actually breaks" in the evaluation). Therefore:

**Fork `tailscale/libtailscale` under our org; point the submodule at the
fork.** On the fork branch, as ordinary commits:

1. Absorb the 23 `Patches/` files as commits (mechanical: apply, commit each
   with its filename as subject). The Makefile's patch machinery retires; the
   `.patches-applied` marker, `-F0` loop, and `unapply-patches` all go.
   `Patches/` remains in git history; the README gains a pointer to the fork.
2. Bump `tailscale.com` to v1.102.3 (`go get` + `go mod tidy`, both verified).
3. Add the guest backend as a new package `guest/` in the fork (below).

Upstreaming the upstreamable patches (missing imports, the poll-timeout fix,
the fd race, Linux portability, Windows support) continues from the fork —
now as normal PRs — and shrinks our delta over time. Rebasing on upstream's
(nearly dormant: one additive commit) main is a merge, not a patch re-roll.

### The guest backend (`guest/` package in the fork)

Vendored from tailcat at `c04c5af` (BSD-3, header preserved), modified:

- **UDP through the tunnel**: a second `filter.Match` for `ipproto.UDP`
  (destinations: the server's own address, port 7447 only), a UDP forwarder
  registered on the gVisor stack, and a real `NetstackDialUDP` on the client
  side. This is the code tailcat lacks and we own outright — no upstream wait.
  (Still file the tailcat issue; if it lands we converge, but nothing here
  blocks on it.)
- **Eviction**: `RemoveClient(nodekey)` — delete from the clients map, rebuild
  the netmap without the peer, push to magicsock, and add the key to a local
  denylist so a re-`meow` is ignored. Node IDs become monotonic (a counter,
  not `len(clients)+2`) so removal can't collide IDs. This closes the
  "append-only clients map" gap the evaluation found.
- **Token**: tailcat's `ConnBlob` unchanged (CBOR, field names pinned by the
  vendored `TestWireFieldNames`). We always emit the **full-address** form
  (embedded DERP region) so viewers never fetch a DERP map. Presented to
  users as `tailscreen:join?t=<blob>` and as the bare blob for copy-paste.
- **DERP**: default to the tailcat public map for bootstrap; a settings
  override (`derpmap URL` / region hostname) feeds straight through to the
  vendored `DERPMapURL`/`Region` fields. `docs/self-hosted.md` gains the
  derper recipe. (Public relays are rate-limited: fine for bootstrap +
  hole-punched direct paths, **not** a place to sustain relayed video — the
  UI copy and docs must say so, and the sharer should surface "relayed"
  per-guest, which magicsock status already exposes.)

C exports (same style as the existing `tailscale_*` surface; socketpair
bridge for data paths, reusing the patch-013 framing):

```
guest_server_start(derp_config) -> handle          // fresh ephemeral key
guest_server_token(handle, buf)                    // full-address ConnBlob
guest_server_listen_packet(handle, port) -> fd     // UDP 7447 in guest stack
guest_server_listen(handle, port) -> ld            // TCP 7447 (control)
guest_server_remove_peer(handle, nodekey)          // eviction + denylist
guest_server_set_peer_callback(handle, cb)         // join/leave + nodekey↔addr
guest_server_stop(handle)                          // key discarded; token dead
guest_client_connect(token) -> handle              // viewer side
guest_client_dial(handle, "udp"/"tcp", port) -> fd
guest_client_close(handle)
```

Go tests in the fork (Phase 1's spike grows into these): loopback server +
client with real DERP/STUN test servers (tailcat's harness, vendored), RTP-
shaped datagrams both directions, relayed and direct, eviction mid-stream.

### Swift: `GuestNode` in TailscaleKit

A small wrapper mirroring the slice of `TailscaleNode` the share stack uses:
`PacketListener`-compatible UDP listen, TCP listen for the control listener,
dial for the viewer. Deliberately shaped so `TailscreenSharer`/
`TailscreenViewerTsnet` code stays transport-agnostic — the seams:

- **Sharer**: `TailscaleScreenShareServer.start` grows an optional
  `guestListeners:` alongside `existingNode:`. Internally the server keeps a
  small routing table addr→owning socket so the fan-out/ACK path
  (`:1894-1904`) replies out the socket a viewer arrived on. Guest addrs
  (`fd7a:115c:a1e0::/48` derived) can never collide with tailnet 100.x/fd7a
  peer addrs *of the tailnet stack* because they live in a different netstack;
  the routing table is still keyed explicitly, not inferred.
- **Identity**: a `ViewerIdentity` enum — `.tailnet(stableID:)` /
  `.guest(nodeKey:)` — replaces the bare StableNodeID in pending rows,
  notifications, and the remembered-decision store. Guest node keys come from
  the peer callback, not from any payload claim. Persisted guest decisions are
  **session-scoped** in v1 (ephemeral keys make "always allow" meaningless
  across shares; the store simply drops `.guest` entries on share stop).
- **Admission**: `SharerDecisions.admissionDecision` gains the rule *guest ⇒
  approval required*, ignoring the toggle. Pure function, CI-tested, same
  pattern as today (`SharerDecisions.swift:105-123`).
- **Eviction**: deny/drop on a `.guest` viewer calls SERVER_BYE (as today)
  **and** `guest_server_remove_peer` — the tunnel actually closes, which is
  stronger than the tailnet case.
- **Viewer**: `ViewerConfig` destination becomes
  `enum Destination { case host(String, port: UInt16); case token(String) }`
  (hostname init kept as a convenience). `TsnetTransport` grows a sibling
  `GuestTransport` sharing the run loop/DatagramInbox machinery — the socket
  comes from `guest_client_dial`, everything above it is untouched. macOS
  `TailscaleScreenShareClient` gets the same branch.

### UI

All new strings through `L(_:)`; `make test-l10n` enforces catalog coverage
across all three apps.

**Sharer — macOS menubar (the sharer tool) + main window:**

- A **Share via Link** row in the menubar share controls, visible while
  sharing (and as an option when starting): toggling it on brings up the
  guest node, shows the token as a one-line code field with **Copy Link** /
  **Copy Token**, a guest count, and **New Link** (rotates: stop guest node,
  fresh key, new token — old token dead). Toggle off / stop share → token
  dead, all guests dropped, copy explains that.
- Pending guests appear in the existing `PendingViewersList` and hub roster
  with a **Guest** badge and the short node-key fingerprint (`nodekey:9c8d…`
  style, first/last 4) instead of a hostname. Same Accept/Deny buttons, same
  notification surfaces (macOS notifications, Windows toast via the existing
  `WindowsToastPayload` identity threading, GNotify on Linux).
- Roster rows for admitted guests show the badge + fingerprint + relay/direct
  indicator; the existing drop control works (and actually evicts, above).

**Viewer — hub, all three apps:**

- **Join a Share…** as a hub-header action (next to Refresh/Add Account in
  `HubHeader`) and in the macOS empty state: a sheet with one paste field
  (accepts bare token or `tailscreen:` URL), a short "you're joining as a
  guest; the sharer must approve you" line, and Join. Errors (bad token,
  unreachable DERP, timeout) surface through the existing placard states.
- `tailscreen:` URL scheme: register on macOS (Info.plist via SwiftPM
  resources), open straight into the join sheet with the token pre-filled.
  Linux `.desktop` / Windows registry registration are follow-ups tracked in
  `docs/platform-support.md`, not v1 blockers.
- While connected, the viewer toolbar shows the same session UI; a small
  "Guest" chip in the stats overlay is the only difference.

**Settings (macOS `SettingsView`, mirrored later on the other two):**

- "Link sharing" section: enable/disable the feature (default **on** but
  inert until a share uses it), DERP relay override (URL or hostname,
  default public map), and static copy: guests bypass tailnet ACLs; approval
  is always required for them; links die when the share stops.

**Consent posture** (`docs/security.md` gets the matching section): a token
is *capability to knock*, never capability to watch. The knock produces a
pending row; only the sharer's explicit approval admits. Remembered-deny for
a guest key holds for the life of the share (covers "I denied them, they
keep re-knocking" — the tunnel-level denylist silences repeats entirely).

### Wire protocol / spec impact

None on 7447 — the point of the design. The token is transport-plane, owned
by the vendored Go (its CBOR field names pinned by the vendored test, the Go
side being the only parser; Swift treats tokens as opaque strings).
`docs/spec.md` gets a short informative appendix: "Transport bootstrap via
connection token (guest mode)" describing scope — normative requirements
stay zero because nothing on the wire inside the tunnel changed. Admission
identity prose in `security.md`/spec notes the second identity class.
`WireByteRegistryTests` untouched; no vectors added.

## Phases & gates

**Phase 0 — Own the archive.** Fork libtailscale; patches→commits;
*(status: fork exists at `middle-management/libtailscale`; `tailscreen-main`
carries the 23 converted patch commits — byte-identical to the old
`make apply-patches` tree — plus the `tailscale.com` → v1.102.3 bump
(`bf3db96`). The submodule, `Packages/TailscaleKit/Makefile`, the CI
bootstrap action, and the docs are flipped to the fork and the patch
machinery is gone. Remaining for the gate: green CI on all legs and a
Swift-toolchain machine confirming `make build` / `make test-protocol` —
this container has no Swift.)*
`tailscale.com` → v1.102.3; submodule → fork; Makefile patch machinery
removed; CI bootstrap uses `go: setup-go` wherever the archive builds.
*Gate*: `make build`, `make test-protocol`, `make test-differential`,
`make test-conformance`, `make test-l10n` all green on macOS + Linux CI, and
a Swift-toolchain machine confirms the previously-unverified Swift half of
the bump. **Land alone** — pure refactor+bump PR, no feature code. Also the
moment `CLAUDE.md`'s "Go 1.21+" line gets corrected.

**Phase 1 — The deciding spike.** In the fork: guest backend vendored, UDP
filter+forwarder added, Go test pushes RTP-shaped datagrams both ways,
relayed and direct. *Gate*: this passing turns the rest into schedule; a
failure here stops the plan and we fall back to TCP-profile investigation
(the reliable-transport profile from the evaluation) before touching UI.
*(status: **passed**. The fork's `guest/` package (PR
middle-management/libtailscale#1) vendors tailcat at `c04c5af` and adds
`OnUDP`/`ServedUDPPorts`/a UDP filter match/`DialUDPPort`. 32 RTP-shaped
1200-byte datagrams round-trip byte-identical on a verified direct path and
verified DERP-relayed, and a filtered port yields silence with `OnUDP`
never called — all under `-race`.)*

**Phase 2 — Guest node, exported.** Full C surface + eviction + tests in the
fork; `GuestNode` Swift wrapper + unit tests in TailscaleKit. *Gate*: a
headless Swift test (linux-runnable, `test-protocol`-adjacent) does
token → connect → datagram echo → evict.
*(status: eviction (`RemoveClient`: denylist, closed flows, monotonic IDs),
the full `guest_*` C surface, and the Swift `GuestServerNode`/`GuestClientNode`
wrappers are on the fork's `guest` branch. The token → connect → 1200-byte
echo → evict → silence gate runs at the C layer — `TestGuestCAPI` drives the
real exported symbols against a local DERP harness, tsnetctest-style — since
a Swift-side full-tunnel test needs a relay harness Swift tests don't have;
the Swift leg's gate is compile+link on `linux-tailscalekit`. Guest fds are
bit-compatible with tsnet fds, so the wrappers vend the ordinary
`PacketListener`/`Listener`/`IncomingConnection` types.)*

**Phase 3 — Core integration.** Server dual-listener routing,
`ViewerIdentity`, admission rule, viewer `Destination.token` +
`GuestTransport`.
*(status: core landed. Sharer: `start(guestPacketListener:)` feeds guest
datagrams through the same pipeline via the `MediaSockets` routing facade;
guests are tagged by arrival listener, always park behind the approval
prompt (open-door, remembered-allow and pre-approval all excluded, pinned
by truth-table tests), and a deny/remembered-deny fires
`onGuestViewerDenied` for tunnel-level eviction. `ViewerInfo`/
`PendingViewerInfo` carry `isGuest` — implemented as a flag plus the guest
node key from `GuestServerNode.peers()` rather than the planned enum, since
the addr-keyed rosters made the flag the smaller honest change. Viewer:
`ViewerConfig.guestToken` (spelled so instead of a `Destination` enum —
same reasoning) routes `TsnetTransport.run` through the guest tunnel with
no tsnet node; the session core is extracted as `runSession`, shared by
both paths; the dest filter comes from `guest_client_server_addr`, pinned
in the fork's ctest against the address real frames carry. Deferred to a
follow-up: the guest TCP control channel (annotations/remote control for
guests) on both sides, and `test-local.sh --guest`, which needs the phase-4
host wiring.)* Extend `test-local.sh` with a `--guest` mode; net-impair
runs over the guest path. *Gate*: two local instances, one tailnet-less,
full session: pending → approve → video+annotations+remote-control → drop.
Pure-decision suites extended per the test-catalog conventions (admission
with guest, routing pick, token/URL parse+display formatting).

**Phase 4 — UI, macOS first.** Menubar Share-via-Link, join sheet, badges,
settings, URL scheme, notifications copy. *Gate*: `make test-l10n` green;
hand-run of the full flow on two Macs across different networks (one
CGNAT'd), confirming direct-path upgrade and the relayed indicator.

**Phase 5 — Cross-platform viewer + docs.** HubUI join entry (lights up
Linux+Windows viewers nearly for free via `GuestTransport`), platform matrix
updates, `docs/usage.md` walkthrough, `docs/security.md` guest section,
`docs/self-hosted.md` derper recipe, spec appendix. Sharer-side guest mode on
Linux/Windows rides the same `SharerModel`/WGC hosts afterwards, tracked as
matrix gaps per `plans/platform-alignment.md`'s rule (a *decision* — approve,
deny, drop a guest — must exist wherever guests can exist, so those land with
the sharer port, not after it).

Each phase is a separate PR; 0 and 1 can proceed in parallel (1 targets the
fork directly). Docs ship with their phases per the repo rule, safe under the
/next preview channel.

## Files to change / add (by phase)

- **0**: `.gitmodules` (fork URL), `Packages/TailscaleKit/Makefile` (patch
  machinery out), `Patches/` (removed; README pointer), `.github/**`
  (bootstrap `go: setup-go`), `CLAUDE.md` (Go floor).
- **1–2 (fork)**: `guest/` package (~vendored 2 kloc + our UDP/eviction),
  `guestnode.c`/exports, tests. **(repo)**
  `Packages/TailscaleKit/Sources/GuestNode.swift` (+ PacketListener conformance).
- **3**: `TailscaleScreenShareServer.swift` (dual listeners, routing,
  identity), `SharerDecisions.swift`, `SharerAskToShareCoordinator.swift`
  (guest control listener attach), `TailscreenViewerTsnet/GuestTransport.swift`,
  `ViewerConfig`, macOS `TailscaleScreenShareClient.swift`,
  `scripts/test-local.sh`, new suites per test-catalog.
- **4**: `MenuBarView.swift`, `MainWindowView.swift`, `SettingsView.swift`,
  `AppState.swift`, `ViewerApproval.swift` (guest copy),
  `TailscreenUserNotifications.swift`, L10n catalog.
- **5**: `TailscreenHubUI/HubHeader.swift` + join sheet, `Apps/linux`,
  `Apps/windows` glue, `docs/{usage,security,self-hosted,platform-support}.md`,
  `docs/spec.md` appendix.

## Risks & mitigations

- **Relayed guests saturate public DERP** → per-guest relay indicator, docs
  push to self-hosted derper, and (stretch) a sharer-side cap: warn when a
  guest stays relayed at high bitrate. The quality-settings machinery already
  adapts bitrate per viewer (`plans/per-viewer-fairness.md`).
- **MTU**: tunnel MTU 1360 (< tsnet path today). RTP packetization already
  targets ≤1200 B payloads (`DatagramInbox` sizing) — verify in the Phase 1
  spike, clamp there if needed.
- **Fork drift**: upstream libtailscale is near-dormant (one commit in the
  evaluation window), and continued upstreaming of the old patches shrinks
  the delta. The fork is strictly less fragile than the `-F0` patch series
  it replaces (already bitten once: patch 021).
- **Token leakage**: mandatory approval + ephemeral keys bound the damage to
  "someone can knock until the share ends"; tunnel-level denylist silences a
  noisy knocker; New Link rotates instantly.
- **Two netstacks' memory/CPU** on the sharer: guest node starts only when
  Share-via-Link toggles on, torn down on stop; measure in Phase 3's
  net-impair runs.

## Estimated scope

Phase 0 ~a week including CI soak; Phase 1 days (the code exists, the test is
the work); Phase 2 ~a week (C surface + Swift wrapper + tests); Phase 3 the
core week-to-two (routing + identity threading is the bulk); Phase 4 ~a week
of UI + copy + l10n; Phase 5 spread out. Nothing blocks on upstream.
