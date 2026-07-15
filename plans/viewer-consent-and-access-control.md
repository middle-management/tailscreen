# Default-on viewer consent, persistent per-peer allow/deny list, and a finished accept/decline handshake

> Status: proposed — this PR contains only the plan; implementation is a follow-up iteration.

## Problem & motivation

Anyone on the tailnet can watch a Tailscreen share the moment it starts. The "Require approval for new viewers" gate exists but **defaults OFF**: `ViewerApprovalDefaults.load()` is a bare `UserDefaults.standard.bool(forKey:)` (`Sources/ViewerApproval.swift:12-14`), which returns `false` when unset, and the server's gate lock also initializes to `false` (`Sources/TailscaleScreenShareServer.swift:136`). In open-door mode a single HELLO datagram registers the viewer straight into the video/audio fan-out (`registerOrRefresh`, `TailscaleScreenShareServer.swift:940-1055`) and the sharer only learns after the fact via a "Viewer Connected" notification (`AppState.swift:1772-1786` → `ViewerApproval.swift:42-55`). There is no memory of past decisions — every session re-prompts for trusted teammates and re-admits people the sharer already rejected — and the request-to-share flow is a one-way nudge: `TailscreenRequest.acceptShare`/`.declineShare` are Codable scaffolding (`Sources/TailscreenMetadata.swift:27-70`) that nothing ever sends or handles, so a requester never learns whether the other side saw, accepted, or declined.

## Goals

1. Flip viewer approval **default-on** for users who never touched the toggle, preserving an explicit opt-out.
2. Persistent per-peer **allow/deny list** keyed by the spoof-resistant Tailscale StableNodeID: "Always allow" skips future prompts; "Deny & block" silently rejects future HELLOs.
3. Settings pane section listing remembered peers with removal.
4. Finish the **accept/decline round-trip** for request-to-share so the requester gets feedback.

## Non-goals

- Auto-connecting the requester when a request is accepted (feedback only; auto-connect is a follow-up).
- Changing the UDP video/audio protocol, port 7447, or the pending-viewer 60 s timeout semantics.
- Cross-device sync of the allow/deny list; per-Mac `UserDefaults` is sufficient.
- Notification-action buttons (Accept from the banner) — dev builds can't post notifications at all (`ViewerApproval.swift:32-38`); the popover stays the primary surface.

## Current state (file:line)

- **Gate default off**: `ViewerApproval.swift:12-14` (key `requireViewerApproval`, line 10); server lock `TailscaleScreenShareServer.swift:136`; AppState `@Published var requireViewerApproval` persists on didSet and syncs the live server (`AppState.swift:92-97`), and is pushed to the server before `start()` (`AppState.swift:585`).
- **Open-door join**: HELLO → `registerOrRefresh(addr:isNew:true)` (`TailscaleScreenShareServer.swift:793-820`); un-gated path inserts into `viewers` and ACKs immediately (`:994-1028`). Approval path parks in `pendingViewers` (`:964-991`), echoes HELLO_PENDING (`:810-819`), and includes a toggle-off-race self-promote (`:983-990`).
- **Approval machinery**: `setRequireApproval` drains pending → `approveViewer` on toggle-off (`:1061-1077`); `approveViewer` (`:1083-1130`) emits the deferred HELLO_ACK + keyframe; `denyViewer` (`:1135-1152`) sends 3× SERVER_BYE; pending entries expire after `pendingApprovalTimeoutNs` = 60 s (`:141`) via the idle sweep (`staleAddrs`, `:1269-1273`; `sweepIdleViewers`, `:1289+`). AppState pass-throughs `approvePendingViewer`/`denyPendingViewer` (`AppState.swift:1806-1814`); Accept/Deny rows in `PendingViewersList` (`MenuBarView.swift:560-596`).
- **Identity today**: viewers are keyed by UDP source `"ip:port"`; `resolveHostnameAndUpdate` / `resolvePendingHostnameAndUpdate` (`TailscaleScreenShareServer.swift:1242-1263`, `:1215-1236`) match the IP against LocalAPI `backendStatus().Peer[*].TailscaleIPs` and keep only `HostName`. LocalAPI's `PeerStatus.ID` is the **string StableNodeID** ("nXXXX…"), distinct from the netmap's numeric node ID — documented at `TailscalePeerDiscovery.swift:174-186` and `TailscaleIPNWatcher.swift:68`.
- **Request-to-share**: one-way. `sendRequestToShare` dials TCP/7447, writes one `.requestToShare` frame (type 0x04, `ScreenShareProtocol.swift:28-31`), and immediately closes (`TailscreenMetadata.swift:162-186`). Receiver: `TailscreenControlListener.dispatch` drops the connection ID for this message type (`TailscreenControlListener.swift:161-168`) → `AppState.handleIncomingRequestToShare` (`AppState.swift:1555-1559`) → banner whose Decline/Share buttons only act locally (`MenuBarView.swift:199-210`). `.acceptShare`/`.declineShare` (`TailscreenMetadata.swift:29-30`) have no wire type, no sender, no handler.
- **Viewer-side denial UX**: SERVER_BYE is the only reject signal and is indistinguishable from "sharer stopped" (`TailscaleScreenShareClient.swift:425-428`); HELLO_PENDING drives the waiting placard (`:436-437`, `AppState.swift:153-158`).

## Design

### Identity model

Persist decisions by **StableNodeID** (`PeerStatus.ID` from LocalAPI `backendStatus()`), displaying the MagicDNS hostname alongside. Rationale: tailscale IPs of ephemeral nodes can be recycled, hostnames/MagicDNS names change on rename, node *keys* rotate on re-auth, and the netmap's numeric ID differs per API (`TailscalePeerDiscovery.swift:174-186`); StableNodeID is the one identifier that survives all of these.

**Spoofing surface — state it explicitly**: a viewer is identified by its UDP source address, but within a tailnet that address is trustworthy. tsnet's userspace netstack only delivers packets that arrived through a WireGuard tunnel whose session key was negotiated against a netmap-authenticated peer, so a peer cannot forge another peer's 100.x source address. The addr → IP (`ipFromAddr`, `TailscaleScreenShareServer.swift:1201-1208`) → netmap peer → StableNodeID mapping is therefore as strong as tailnet membership. The only unauthenticated inputs are wire *payload claims* (e.g. `fromHostname` in `RequestToSharePayload`, already clamped at `ScreenShareProtocol.swift:104-107`) — never key policy on those. If LocalAPI resolution fails (peer absent from netmap), treat the viewer as unknown: park pending, never auto-allow.

### Approval flow

1. `ViewerApprovalDefaults.load()` becomes `UserDefaults.standard.object(forKey: key) as? Bool ?? true` — **migration for free**: users who ever flipped the toggle have a stored Bool (didSet at `AppState.swift:94` persists it) and keep their choice; never-touched installs flip to ON. Add an env escape `TAILSCREEN_OPEN_DOOR=1` → load() returns false, for `test-local.sh`/harness runs (see Risks).
2. HELLO from unknown addr parks in `pendingViewers` exactly as today. The hostname-resolution task (`resolvePendingHostnameAndUpdate`) additionally captures `stableID` into `PendingViewerInfo`, then consults the policy map:
   - `.allow` → call `approveViewer(addr:)` (auto-admit, no prompt; still fires the "Viewer Connected" notification).
   - `.deny` → call `denyViewer(addr:)` (SERVER_BYE) and log; no notification, no pending row (remove before `notifyPendingViewersChanged` surfaces it — resolution is async, so a brief pending flash is acceptable v1 behavior; note it in the row copy).
   - none → normal pending flow (notification via `handlePendingViewersChanged`, `AppState.swift:1792-1802`).
   Extract the choice as a pure static `admissionDecision(policy: PeerPolicy?, requireApproval: Bool) -> Admission` (`.admit`/`.park`/`.reject`) so it's CI-testable, mirroring `audioRelayDecision` (`TailscaleScreenShareServer.swift:867-874`).
3. The server can't touch `UserDefaults` (it's `@unchecked Sendable`, off-main): AppState pushes a value snapshot via `server.setAccessPolicies([String: PeerPolicy])` (an `OSAllocatedUnfairLock` map, same pattern as `requireApproval` at `:136`) at start and whenever the store changes.
4. `setRequireApproval(false)`'s drain (`:1069-1076`) and the toggle-off-race self-promote (`:988-990`) must consult the blocklist: blocked peers get `denyViewer`, not `approveViewer`.
5. Pending 60 s timeout machinery (`:141`, sweep) is untouched — remembered-allow peers simply never enter it.

### Persistence

New `Sources/ViewerAccessPolicy.swift`:

```swift
struct PeerAccessEntry: Codable, Sendable, Identifiable { let stableID: String; var displayName: String; var policy: PeerPolicy; let addedAt: Date }
enum PeerPolicy: String, Codable, Sendable { case allow, deny }
@MainActor final class ViewerAccessPolicyStore: ObservableObject { /* JSON blob under UserDefaults key "viewerAccessPolicies"; init(defaults: UserDefaults = .standard) for testability; @Published entries; upsert/remove/policy(for:) */ }
```

Owned by AppState; `displayName` refreshed on each sighting so renames stay readable.

### Protocol changes

- **TCP control channel** (`ScreenShareProtocol.swift`): new message type `case shareResponse = 0x05`, payload = JSON-encoded existing `TailscreenRequest` (reusing the scaffolded `.acceptShare`/`.declineShare` cases, `TailscreenMetadata.swift:27-70`). Backward compatible: old peers' parsers drop unknown type bytes (`ScreenShareProtocol.swift:79-82`).
- **Response routing**: reply on the **same TCP connection** the request arrived on — no dial-back, so the response provably goes to the actual requester. `TailscreenControlListener.dispatch` passes `connectionID` to `onRequestToShare` (like `.annotation`, `:163-164`); `PendingRequest` (`TailscreenMetadata.swift:78-88`) gains `connectionID: UUID?`; banner buttons send via `controlListener.send(_:to:)` (`TailscreenControlListener.swift:90-93`), best-effort if the connection died.
- **Requester side**: `sendRequestToShare` (`TailscreenMetadata.swift:162-186`) stops closing immediately; after the send it reads frames with `ScreenShareMessageParser` under a generous timeout (120 s, `TailscalePeerDiscovery.withWatchdog`) and returns `.accepted`/`.declined`/`.noAnswer` (timeout/EOF ⇒ `.noAnswer`, which is also what an old peer produces). `AppState.requestToShare` (`AppState.swift:1676-1689`) surfaces the outcome via `presentError`-style alert or notification.
- **UDP control byte (optional, small)**: `helloDenied = 0x09` (0x00–0x08 are taken, `RTPPacket.swift:28-46`; stays < 0x80 per `looksLikeControl`) sent by `denyViewer` alongside SERVER_BYE so the viewer can show "The sharer declined your request" instead of the generic peer-closed teardown (`TailscaleScreenShareClient.swift:423-441`). Old viewers ignore unknown control bytes.

### UI

- **PendingViewersList** (`MenuBarView.swift:560-596`): Accept and Deny each become a split control — primary click behaves as today; a small chevron `Menu` adds "Always Allow" / "Deny & Block", routed to new AppState funcs `approvePendingViewerAlways(_:)` / `denyPendingViewerAndBlock(_:)` which upsert the store (using the `stableID` now carried on `PendingViewerInfo`) then call the existing pass-throughs.
- **SettingsView** (`SettingsView.swift:21-30`): under the existing "Viewers" section (toggle copy updated to reflect the new default), add a "Remembered viewers" list — one row per `PeerAccessEntry` with policy badge and a Remove button; empty-state caption.
- **Request banner** (`MenuBarView.swift:170-217`): Decline sends `.declineShare` then clears; Share sends `.acceptShare`, clears, then `presentNativePicker()`.
- All new strings via `L(_:)` + `Sources/Resources/en.lproj/Localizable.strings` (enforced by `LocalizationCatalogTests`).

## Implementation steps

1. [ ] `Sources/ViewerAccessPolicy.swift`: `PeerPolicy`, `PeerAccessEntry`, `ViewerAccessPolicyStore` (injectable `UserDefaults`), plus pure `admissionDecision(policy:requireApproval:)` (put it here or as a static on the server, matching the extract-the-decision pattern).
2. [ ] `Sources/ViewerApproval.swift:12-14`: tri-state `load()` (`object(forKey:) as? Bool ?? true`) + `TAILSCREEN_OPEN_DOOR=1` escape; update the doc comment.
3. [ ] `TailscaleScreenShareServer.swift`: add `stableID: String?` to `ViewerInfo`/`PendingViewerInfo` (`:31-49`); add `accessPolicies` lock + `setAccessPolicies(_:)`; extend both resolve functions (`:1215-1263`) to capture `PeerStatus.ID` and, in the pending variant, apply `admissionDecision` → `approveViewer`/`denyViewer`; fix the `setRequireApproval(false)` drain (`:1069-1076`) and the race self-promote (`:988-990`) to deny blocked peers; add `helloDenied` emit in `denyViewer` (`:1135-1152`).
4. [ ] `RTPPacket.swift:28-46`: add `helloDenied = 0x09`; `TailscaleScreenShareClient.swift:423-441`: handle it (new `onDeniedBySharer` callback → AppState alert + disconnect).
5. [ ] `ScreenShareProtocol.swift`: `shareResponse = 0x05` message type, encode/decode using `TailscreenRequest` as payload; clamp/validate like `:104-107`.
6. [ ] `TailscreenControlListener.swift:161-168`: pass `connectionID` through `onRequestToShare`; add `onShareResponse` (unused server-side, harmless).
7. [ ] `TailscreenMetadata.swift`: `PendingRequest` + `connectionID: UUID?` (`:78-88`); `sendRequestToShare` → `sendRequestToShareAwaitingResponse` returning `.accepted/.declined/.noAnswer` (`:162-186`).
8. [ ] `AppState.swift`: own `ViewerAccessPolicyStore`; push snapshots to server at `:585` and on store change; new funcs `approvePendingViewerAlways`/`denyPendingViewerAndBlock` (`near :1806-1814`); thread `connectionID` through `handleIncomingRequestToShare` (`:1555-1559`); surface request outcome in `requestToShare` (`:1676-1689`).
9. [ ] `MenuBarView.swift`: split Accept/Deny controls (`:560-596`); banner responses (`:199-210`).
10. [ ] `SettingsView.swift`: remembered-viewers section; update toggle caption.
11. [ ] `en.lproj/Localizable.strings`: add every new `L("…")` key byte-for-byte.
12. [ ] Tests (below) + set `TAILSCREEN_OPEN_DOOR=1` in `test-local.sh` and the harness/E2E helpers that assume open-door joins.
13. [ ] Update `CLAUDE.md` (protocol section: new 0x05 TCP type + 0x09 control byte; testing list: new suites) in the same commit, per its own header rule.

## Files to change / add

Add: `Sources/ViewerAccessPolicy.swift`, `Tests/TailscreenTests/ViewerAccessPolicyTests.swift`, `Tests/TailscreenTests/ShareResponseProtocolTests.swift`, `Tests/TailscreenTests/ScreenShareAccessControlTests.swift` (local-only E2E).
Change: `Sources/ViewerApproval.swift`, `Sources/TailscaleScreenShareServer.swift`, `Sources/TailscaleScreenShareClient.swift`, `Sources/RTPPacket.swift`, `Sources/ScreenShareProtocol.swift`, `Sources/TailscreenControlListener.swift`, `Sources/TailscreenMetadata.swift`, `Sources/AppState.swift`, `Sources/MenuBarView.swift`, `Sources/SettingsView.swift`, `Sources/Resources/en.lproj/Localizable.strings`, `test-local.sh`, `Tests/TailscreenTests/TailscreenE2EHelpers.swift`, `Tests/TailscreenTests/ScreenShareRequestToShareTests.swift`, `CLAUDE.md`.

## Testing strategy

**CI-able (pure logic, no tsnet/SCK — per CLAUDE.md the tsnet suites are local-only):**
- `ViewerAccessPolicyTests`: store round-trip against an injected `UserDefaults(suiteName:)`; upsert/remove/rename-refresh; `admissionDecision` truth table (allow×gate-on/off, deny×gate-on/off, unknown×both); migration matrix for `ViewerApprovalDefaults.load()` — unset→true, stored-false→false, stored-true→true, `TAILSCREEN_OPEN_DOOR` override.
- `ShareResponseProtocolTests`: `ScreenShareMessageParser` round-trips `shareResponse` accept/decline; unknown-type byte still skipped (old-peer compat, `ScreenShareProtocol.swift:79-82`); oversized/garbage payload rejected.
- Extend the extract-the-decision roster (and CLAUDE.md's list): the drain-respects-blocklist choice in `setRequireApproval(false)` as a pure function over `(pendingIDs, policies)`.

**Local-only E2E (headscale, `make test-e2e-local`):**
- `ScreenShareAccessControlTests` (pattern of `ScreenShareSyntheticFramesTests` — headless `filterData: nil` server): (a) allow-listed viewer's HELLO auto-admits without `onPendingViewersChanged` sticking; (b) blocked viewer receives SERVER_BYE + `helloDenied` and never appears in `onViewersChanged`; (c) unknown viewer parks pending and `approveViewer` still works (regression). Policy map injected via `setAccessPolicies` with the StableNodeID read from the viewer node's own LocalAPI status.
- Extend `ScreenShareRequestToShareTests` (two raw tsnet nodes): request → responder sends `.declineShare` on the same connection → requester's await returns `.declined`; timeout path returns `.noAnswer`.
- Manual pass with `./test-local.sh 2` (with and without `TAILSCREEN_OPEN_DOOR=1`) covering the popover split buttons and Settings removal.

## Risks & pitfalls

- **Default flip breaks automated joins**: `TAILSCREEN_AUTOCONNECT_TO`, the log-marker harness, and `test-local.sh` all assume open-door HELLO. Without step 12's `TAILSCREEN_OPEN_DOOR=1` the viewer parks 60 s and the harness times out. Direct-constructed test servers are unaffected (server lock still defaults false, `TailscaleScreenShareServer.swift:136` — only AppState reads the UserDefault).
- **Concurrency**: the server is `@unchecked Sendable`; the policy map must be an `OSAllocatedUnfairLock` snapshot, never a `UserDefaults`/`@MainActor` reach-in. Store mutations stay on `@MainActor` (Swift 6 strict concurrency).
- **Race windows**: preserve the toggle-off self-promote at `:983-990` — its fix must go through `admissionDecision`, not around it. Auto-deny happens post-async-resolution; a HELLO retry storm from a blocked peer must stay idempotent (`denyViewer` already no-ops on unknown addr, `:1139`).
- **Payload trust**: never key policy on `fromHostname` or any wire payload — StableNodeID from our own LocalAPI lookup only. Responses ride the request's own TCP connection precisely to avoid dialing back a claimed hostname.
- **Held-open request connections**: banner is suppressed while busy (`MenuBarView.swift:179-180`) so a response may fire minutes later on a dead connection — must be best-effort (listener `send` already swallows errors, `TailscreenControlListener.swift:90-93`); requester treats EOF as `.noAnswer`.
- **Localization**: every new user-facing string needs an `en.lproj` catalog entry or `LocalizationCatalogTests` fails CI.
- **CLAUDE.md contract**: protocol/testing sections must be updated in the same commit; port 7447 stays hardcoded; no `SCShareableContent`/picker/capture changes anywhere near this work.

## Estimated scope

**M** — roughly 700–1000 LOC total: ~120 store+decision, ~150 server, ~80 protocol/listener/metadata, ~120 AppState, ~150 UI, ~40 strings/scripts/docs, ~300 tests. No build-system, patch, or helper-subprocess changes.
