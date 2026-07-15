# Share system/computer audio to viewers

> Status: proposed — this PR contains only the plan; implementation is a follow-up iteration.

## Problem & motivation

Tailscreen viewers see the sharer's screen but hear nothing the sharer's Mac is playing. Voice chat exists (mic ↔ mic over AAC/RTP), but demoing a video, an app with sound, or a build with audio cues is silent for viewers. ScreenCaptureKit can deliver system audio from the same `SCStream` that already captures video (`SCStreamConfiguration.capturesAudio` + an `.audio` stream output), and the app already has a complete AAC/RTP audio transport for voice — the work is plumbing captured system audio through the existing helper-subprocess wire and the existing UDP/7447 audio fan-out, tagged so viewers can tell it apart from voice.

## Goals / Non-goals

**Goals**
- Sharer can toggle "Share System Audio" per share; viewers hear the sharer's computer audio mixed alongside voice chat.
- System audio is a distinct RTP payload type + reserved SSRC so viewers demux it from voice without negotiation (same philosophy as video's PT 96/97 auto-detect, `Sources/RTPPacket.swift:8-9`).
- No echo of viewer voices back to viewers via the captured system audio.
- Older viewers that predate the feature silently ignore the new packets (no crash, no torn video/audio).
- CI-able pure-decision tests for every new branch; local E2E coverage via the existing suite patterns.

**Non-goals**
- Stereo. v1 is AAC-LC **mono 48 kHz**, identical to voice, so the viewer reuses `AACDecoder` unchanged (`Sources/AACCodec.swift:212-273`, decoder is hardwired mono/48k with a shared magic cookie). Stereo needs a second decoder config + cookie — future work.
- Per-app audio filtering, viewer-side volume slider, capability negotiation in HELLO. All future work.
- Changing voice chat behavior or the viewer-to-viewer voice relay.

## Current state (with file:line references)

- **Capture config is video-only.** `SCStreamConfiguration` built at `Sources/ScreenCapture.swift:232-243` sets width/height/fps/pixelFormat only; the single stream output is added for `.screen` only (`ScreenCapture.swift:276`) and `StreamOutput.stream(_:didOutputSampleBuffer:of:)` drops anything that isn't `type == .screen` with an image buffer (`ScreenCapture.swift:540`).
- **Capture/encode run in the helper subprocess.** `CaptureHelperRunner` (in `Sources/CaptureHelperMain.swift:213-482`) owns `ScreenCapture` + `VideoEncoder`; encoded AUs are written synchronously from the encoder thread (`CaptureHelperMain.swift:400-411`) via `HelperFrameWriter` (`Sources/CaptureHelperWire.swift:89-150`, lock-serialized, currently 3 writer threads per the comment at :91-95).
- **Helper wire protocol.** `CaptureHelperWire.OutType` (`CaptureHelperWire.swift:19-57`): 0x01 accessUnit … 0x06 heartbeat, 0x10 logLine, 0xFF fatal. `InType` (:60-76): 0x01 requestKeyframe, 0x02 setBitrate, 0x03 contentFilter, 0xFF shutdown. Parent-side parsing in `HelperScreenCapture.readLoop()` (`Sources/HelperScreenCapture.swift:175-244`).
- **Voice audio stack.** `AACEncoder`/`AACDecoder` (mono 48 kHz, 1024 samples/AU, 64 kbps, `Sources/AACCodec.swift:24-74`). `AudioRTPPacketizer` hardcodes `RTPHeader.aacPayloadType` = 98 (`Sources/RTPAudio.swift:26`, PT defined at `RTPPacket.swift:89`); `AudioRTPDepacketizer.unpack` rejects any other PT (`RTPAudio.swift:52`). `VoiceChannel.receive` decodes per-SSRC and emits `onMixedPCM` (`Sources/VoiceChannel.swift:72-105`); `MicCapture.scheduleSamples` plays blocks into `playerNodes.first` (`VoiceChannel.swift:725-752`) with a jitter buffer and `maxPendingBuffers = 6` cap (:718).
- **Server audio fan-out.** Sharer mic packets go out via `TailscaleScreenShareServer.sendAudioRTP` chained on `audioBroadcastTail` (`Sources/TailscaleScreenShareServer.swift:1594-1606`, tail at :185). Inbound viewer audio is gated by `audioRelayDecision` (anti-spoof SSRC check, :873-882) and only PT 98 is accepted from viewers (:780-788). Viewer audio SSRCs are random `1...UInt32.max` (:968, :1000-1007); the sharer's own voice SSRC is fixed at 0 (`Sources/AppState.swift:593`).
- **Viewer receive path.** `TailscaleScreenShareClient.receiveLoop` routes PT 98 datagrams to `onAudioReceived` (`Sources/TailscaleScreenShareClient.swift:443-449`); unknown PTs fall through to `MultiCodecDepacketizer.ingest`, which returns nil for anything but 96/97 (`RTPPacket.swift:1001-1011`) — i.e. old viewers already drop unknown audio safely.
- **Helper lifecycle.** `startHelperCapture` wires callbacks and passes the `forceH264` latch on every (re)spawn (`TailscaleScreenShareServer.swift:476-588`); `restartCapture` respawns against cached `lastFilterData` (:609-668). Any new per-share audio flag must ride the same respawn path.
- **UI.** SharingCard button row: Draw + Mic icon buttons + Stop Sharing (`Sources/MenuBarView.swift:422-458`; comment at :419-421 explains icon-only policy). Persisted-toggle pattern: `ViewerApprovalDefaults` (`Sources/ViewerApproval.swift:10-17`) + `@Published` with `didSet` (`AppState.swift:92-96`). Localization via `L(_:)` with keys in `Sources/Resources/en.lproj/Localizable.strings`, enforced by `LocalizationCatalogTests`.

## Design

### Wire/protocol changes

- **RTP:** new `RTPHeader.systemAudioPayloadType: UInt8 = 99` next to 96/97/98 (`RTPPacket.swift:83-91`), and a reserved constant `RTPHeader.systemAudioSSRC: UInt32 = 1`. Parametrize `AudioRTPPacketizer.init` with `payloadType` (default `aacPayloadType`, so voice call sites are untouched); `AudioRTPDepacketizer.unpack` accepts PT ∈ {98, 99} and callers branch on the already-exposed `Parsed.payloadType` (`RTPAudio.swift:43-49`). Viewer SSRC allocation in the server excludes the reserved SSRC (change `UInt32.random(in: 1...UInt32.max)` to `2...UInt32.max` at `TailscaleScreenShareServer.swift:968, :1002, :1006, :1096` — sharer voice keeps 0, system audio owns 1).
- **Helper wire:** new `CaptureHelperWire.OutType.audioAccessUnit = 0x07` (payload = raw AAC AU bytes; no flags needed) and new `InType.setAudioEnabled = 0x04` (payload = 1 byte, 0/1). The SCStream is configured with `capturesAudio = true` whenever the share *starts* with audio allowed; the toggle gates **emission** in the helper (drop AUs while disabled) so mute/unmute is instant and avoids `updateConfiguration` churn on the audio path.
- **Timestamping:** the packetizer's existing +1024-per-AU clock (`RTPAudio.swift:34`) is kept. Viewer playback is queue-paced, not timestamp-paced (`VoiceChannel.swift:725-752`), so capture gaps just drain the jitter queue; the `maxPendingBuffers` cap bounds drift.

### Helper changes (capture + AAC encode happen in the helper)

Rationale: capture cannot leave the helper (CLAUDE.md: all SCStream lifecycle lives in the child), and encoding beside it (a) mirrors the video pattern — encode in helper, packetize/fan-out in parent, (b) keeps pipe traffic tiny (~170 B AUs at ~47 Hz vs 192 KB/s raw PCM), (c) reuses `AACEncoder` verbatim (it's AudioToolbox-only, process-agnostic).

- `ScreenCapture.swift`: add `var capturesAudio: Bool` knob consumed in `startStream` (`:232-243`): `config.capturesAudio = true`, `config.sampleRate = 48_000`, `config.channelCount = 1`, `config.excludesCurrentProcessAudio = true`. Add `var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?` and a second `addStreamOutput(output, type: .audio, sampleHandlerQueue: <dedicated serial queue>)` beside `:276`. In `StreamOutput`, handle `type == .audio` before the `.screen` guard at `:540` and forward the CMSampleBuffer. Remove the `.audio` output in `stop()` next to `:394-399`.
- New `Sources/SystemAudioTap.swift` (helper-side, no SCK imports): converts an audio `CMSampleBuffer` → `[Float]` mono samples (via `CMSampleBufferGetAudioBufferList` / `AudioBufferList`; SCK delivers Float32 PCM at the configured rate/channels), accumulates into 1024-sample frames (same pattern as `TapBuffer.appendAndDrain`, `VoiceChannel.swift:295-302`), feeds `AACEncoder`, and emits AUs via callback. The framing/accumulation core is a **pure struct** (`SystemAudioFramer`: `mutating func append([Float]) -> [[Float]]`) so CI can test it without CoreMedia buffers.
- `CaptureHelperMain.swift`: `CaptureHelperRunner` owns the tap; wire `captureWrapper.onAudioSampleBuffer` in `startWithFilter` (`:248-290`), writing AUs straight from the audio queue via `writer.writeAudioAccessUnit(_:)` (mirrors the heartbeat's no-MainActor-hop rationale at `:263-268`). Gate on an `audioEnabled` atomic toggled by the new stdin message (switch at `:96-134`). Whether audio capture is configured at all comes from a new optional field in the `contentFilter` JSON payload (see below).
- `CaptureHelperWire.swift`: `HelperFrameWriter.writeAudioAccessUnit(_:)`; update the `writeLock` doc comment (`:91-95`) — four writer threads now.
- `PickerSelection` (`Sources/PickerSelection.swift`): add `var captureAudio: Bool? = nil` (optional → old JSON still decodes; helper treats nil as false). This rides the existing cached-selection respawn path for free (`restartCapture` reuses `lastFilterData`, `TailscaleScreenShareServer.swift:653-658`).

### Server / parent changes

- `HelperScreenCapture.swift`: parse `.audioAccessUnit` in `readLoop()` (`:187-243`) → new `var onAudioAccessUnit: ((Data) -> Void)?`; add `func setAudioEnabled(_ on: Bool)` using `HelperControlWriter` (pattern of `setBitrate`, `:170-173`); extend `HelperControlWriter` with `sendAudioEnabled(_:)` (`CaptureHelperWire.swift:216-243`).
- `TailscaleScreenShareServer.swift`: own `systemAudioPacketizer = AudioRTPPacketizer(ssrc: RTPHeader.systemAudioSSRC, payloadType: RTPHeader.systemAudioPayloadType)`. In `startHelperCapture` (`:476-588`) wire `helper.onAudioAccessUnit` → `broadcastSystemAudio(au:)`: packetize (safe — the helper reader thread is the only caller, satisfying the packetizer's serialization contract, `RTPAudio.swift:8-10`) then fan out through the existing `audioBroadcastTail` exactly like `sendAudioRTP` (`:1594-1606`). Add a `shareSystemAudio` `OSAllocatedUnfairLock<Bool>` latch (pattern of `forceH264`, `:227`): `setShareSystemAudio(_:)` stores it and forwards to the live helper; `startHelperCapture` re-sends it after every (re)spawn so helper restarts preserve the toggle (mirror the `forceH264` handling at `:585`).
- Inbound gate unchanged: viewers can never inject PT 99 — `handleIncoming` only accepts PT 98 from viewers (`:780-788`), which doubles as the anti-spoof rule for system audio.

### Viewer changes

- `TailscaleScreenShareClient.swift`: widen the audio route at `:443-449` to `PT == aacPayloadType || PT == systemAudioPayloadType` → `onAudioReceived` (no new callback; VoiceChannel demuxes by PT).
- `VoiceChannel.swift`: in `receive` (`:72-105`), branch on `parsed.payloadType`: PT 98 → existing `onMixedPCM` path; PT 99 → decode with the same per-SSRC `AACDecoder` machinery, emit via new `var onSystemAudioPCM: (([Float]) -> Void)?`. Extract the routing as a pure static `VoiceChannel.audioRoute(payloadType:) -> AudioRoute` (`voice`/`systemAudio`/`drop`) for CI.
- `MicCapture` (`VoiceChannel.swift:305+`): add a **dedicated** `AVAudioPlayerNode` for system audio with its own pending-buffer counter and jitter threshold, scheduled by a `scheduleSystemAudioSamples(_:)` twin of `scheduleSamples` (`:725-752`). Do not funnel PT 99 into the voice player: two concurrent 50 Hz streams serialized into one node interleave (time-multiplex) instead of mixing — `mainMixerNode` sums the two nodes correctly. Playback through the engine also keeps VPIO AEC's reference signal correct when the viewer's mic is on (`:486-494`), so the viewer's mic doesn't feed the sharer's audio back as voice.
- **Echo avoidance, sharer side:** `excludesCurrentProcessAudio = true` removes Tailscreen's own output — i.e. viewer voices played by `MicCapture` — from the captured mix, so viewer speech is never re-broadcast as system audio. Anything the sharer's speakers play from *other* apps is intentionally captured. The sharer hears their own system audio natively; the helper's AUs are never looped back locally.
- Old-viewer compatibility: PT 99 datagrams fail the PT-98 check at `:444` and return nil from `MultiCodecDepacketizer.ingest` (`RTPPacket.swift:1008-1010`) — silently dropped. Cost is ~10 KB/s of wasted downstream per stale viewer; acceptable, no negotiation needed.

### UI

- `AppState.swift`: `@Published var isSystemAudioOn` + `@Published var shareSystemAudioByDefault` persisted via a new `SystemAudioDefaults` (clone of `ViewerApprovalDefaults`, `ViewerApproval.swift:10-17`; key `"shareSystemAudio"`). `startSharing` sets `PickerSelection.captureAudio` from the default and calls `srv.setShareSystemAudio(_)` before `start()` (mirror `setRequireApproval` at `:585`); new `func toggleSystemAudio()` flips the live latch (pattern of `toggleMic`, `:815-834` — but no permission dance; Screen Recording TCC already covers SCK audio). `stopSharing` resets `isSystemAudioOn` (`:663-697`).
- `MenuBarView.swift` SharingCard: fourth icon-only button between Mic and Stop (`:422-458`): `speaker.wave.2.fill` / `speaker.slash`, `.help(L("Share System Audio"))` etc. Settings (`SettingsView.swift:24` area): `Toggle(L("Share system audio when sharing starts"), isOn: $appState.shareSystemAudioByDefault)`.
- All new strings via `L(_:)`; add keys byte-for-byte to `Sources/Resources/en.lproj/Localizable.strings` (and `sv.lproj` if present).

## Implementation steps

1. `RTPPacket.swift`: add `systemAudioPayloadType = 99`, `systemAudioSSRC = 1`; bump viewer SSRC random ranges to `2...UInt32.max` in `TailscaleScreenShareServer.swift` (:968, :1002, :1006, :1096).
2. `RTPAudio.swift`: parametrize `AudioRTPPacketizer` with `payloadType`; make `AudioRTPDepacketizer.unpack` accept PT 98/99.
3. `CaptureHelperWire.swift`: `OutType.audioAccessUnit = 0x07`, `InType.setAudioEnabled = 0x04`, `HelperFrameWriter.writeAudioAccessUnit`, `HelperControlWriter.sendAudioEnabled`; update writeLock comment.
4. New `Sources/SystemAudioTap.swift`: pure `SystemAudioFramer` (append → 1024-frames) + `SystemAudioTap` (CMSampleBuffer → Float extraction → framer → `AACEncoder` → AU callback).
5. `ScreenCapture.swift`: `capturesAudio` knob into `startStream` config (:232-243) + `.audio` stream output (:276) + `onAudioSampleBuffer` in `StreamOutput` (:516-540) + removal in `stop()` (:394).
6. `PickerSelection.swift`: optional `captureAudio` field.
7. `CaptureHelperMain.swift`: runner owns `SystemAudioTap`; wire in `startWithFilter` (:248); handle `setAudioEnabled` in `installStdinReader` (:96-134); gate emission on the atomic flag.
8. `HelperScreenCapture.swift`: parse `.audioAccessUnit` (:187), add `onAudioAccessUnit`, `setAudioEnabled(_:)`.
9. `TailscaleScreenShareServer.swift`: `shareSystemAudio` latch + `setShareSystemAudio(_:)`; `systemAudioPacketizer`; wire `onAudioAccessUnit` → `broadcastSystemAudio` in `startHelperCapture` (:476); re-send latch after every spawn (:585).
10. `VoiceChannel.swift`: PT routing (`audioRoute` pure func) + `onSystemAudioPCM`; `MicCapture`: dedicated system-audio player node + `scheduleSystemAudioSamples`.
11. `TailscaleScreenShareClient.swift`: widen audio PT check (:443-449).
12. `AppState.swift`: published flags, `SystemAudioDefaults` (new small file or inside `ViewerApproval.swift`'s pattern), `toggleSystemAudio()`, wire `onSystemAudioPCM` where `onMixedPCM` is wired today (sharer :592-605 — sharer path can ignore PT 99, it never receives it; viewer :875-899).
13. `MenuBarView.swift` speaker button; `SettingsView.swift` default toggle; add `Localizable.strings` keys.
14. Tests (below), then update CLAUDE.md's protocol/wire/test-list sections in the same commit (CLAUDE.md's own rule).

## Files to change / add

- **Change:** `Sources/RTPPacket.swift`, `Sources/RTPAudio.swift`, `Sources/CaptureHelperWire.swift`, `Sources/ScreenCapture.swift`, `Sources/CaptureHelperMain.swift`, `Sources/PickerSelection.swift`, `Sources/HelperScreenCapture.swift`, `Sources/TailscaleScreenShareServer.swift`, `Sources/TailscaleScreenShareClient.swift`, `Sources/VoiceChannel.swift`, `Sources/AppState.swift`, `Sources/MenuBarView.swift`, `Sources/SettingsView.swift`, `Sources/Resources/en.lproj/Localizable.strings`, `CLAUDE.md`.
- **Add:** `Sources/SystemAudioTap.swift`; `Tests/TailscreenTests/SystemAudioFramerTests.swift`, `Tests/TailscreenTests/SystemAudioRoutingTests.swift`; extensions to `RTPAudioTests.swift`, `CaptureHelperWireTests.swift`, `ScreenShareFanoutTests.swift`.

## Testing strategy

**CI-able (pure logic, no tsnet/SCK — per CLAUDE.md's extract-the-decision pattern):**
- `SystemAudioFramerTests`: 1024-sample framing — exact boundary, remainder carry, multi-frame drain (mirrors `TapBuffer.appendAndDrain` semantics).
- `RTPAudioTests` additions: packetizer with PT 99 + SSRC 1 emits correct header; depacketizer accepts 98 and 99, still rejects 96/97; timestamp +1024/packet.
- `SystemAudioRoutingTests`: `VoiceChannel.audioRoute(payloadType:)` pure decision; plus an in-process `VoiceChannel.receive` test (synthetic PT 99 packet built from a real `AACEncoder` AU, drained via `flushForTesting`, `VoiceChannel.swift:126-129`) asserting `onSystemAudioPCM` fires and `onMixedPCM` does not. `AACCodecTests` already round-trips encode/decode on CI.
- `CaptureHelperWireTests` additions: `writeAudioAccessUnit` / `sendAudioEnabled` frame round-trips through `HelperFrameReader`/`HelperControlReader`.
- `ViewerLifecycleDecisionTests` addition: viewer SSRC allocation never returns the reserved system SSRC (extract the exclusion as a pure predicate if the random loop resists testing).

**Local-only E2E (per the CLAUDE.md suite patterns):**
- `ScreenShareFanoutTests` extension (local headscale, server in `filterData: nil` mode): add a test-only seam `TailscaleScreenShareServer.broadcastSystemAudioForTesting(au:)` (sibling of `broadcastForTesting`) injecting `AACEncoder`-produced sine AUs; assert both viewers' `onAudioReceived` fires with PT 99 packets that decode to the sine, and that voice relay (PT 98) is unaffected.
- `ScreenShareCaptureHelperTests` extension (local-only, real helper + display): start the share with `captureAudio: true` while the test process plays a tone via `AVAudioEngine`; assert at least one `.audioAccessUnit` frame arrives (self-skip if the runner's audio stack is silent — same skip discipline the suite already uses for CI/virtualized runners).

## Risks & pitfalls

- **All SCK stays in the helper** (CLAUDE.md: never `SCShareableContent`/SCStream in the main process). The audio output, tap, and AAC encoder must live entirely in `CaptureHelperMain`/`ScreenCapture` — the parent only sees AAC bytes on the pipe.
- **`HelperFrameWriter` gains a fourth writer thread** (audio queue). The `writeLock` (`CaptureHelperWire.swift:91-95`) already covers it, but the doc comment must be updated or a future reader will miscount the invariant.
- **Helper restarts must preserve state**: the crash-budget respawn (`TailscaleScreenShareServer.swift:553-583`) and `restartCapture` reuse `lastFilterData`, so `captureAudio` must live in the `PickerSelection` JSON, and the live enable/disable latch must be re-sent post-spawn like `forceH264` (:585) — otherwise a mid-share helper crash silently drops audio or resurrects a muted stream.
- **Viewer mixing**: scheduling two 50 Hz PCM streams into one `AVAudioPlayerNode` interleaves rather than mixes — the dedicated system-audio node is load-bearing, not cosmetic.
- **Echo**: forgetting `excludesCurrentProcessAudio = true` re-broadcasts viewer voices as system audio (feedback loop across the tailnet). Sharer-side VPIO AEC does *not* cover this — the capture is system-wide, not mic.
- **SSRC discipline**: sharer voice = 0 (`AppState.swift:593`), system = 1, viewers ≥ 2. `VoiceChannel.receive`'s own-loopback drop (`VoiceChannel.swift:76`) and the server's anti-spoof gate (`:873-882`) both depend on these spaces staying disjoint.
- **CVPixelBuffer/CMSampleBuffer are not Sendable** — extract `[Float]` on the audio callback queue before crossing any actor boundary (CLAUDE.md Swift 6 conventions; in practice the whole audio path stays off MainActor, like the heartbeat at `CaptureHelperMain.swift:263-268`).
- **Port 7447 untouched**; PT 99 rides the existing UDP socket. No discovery/metadata changes.
- **Localization**: every new UI string needs an `L(_:)` call + a byte-for-byte key in `en.lproj/Localizable.strings` or `LocalizationCatalogTests` fails on CI.
- **TCC**: SCK audio capture is covered by the existing Screen Recording grant — no new permission prompt; do not add a parent-side preflight (explicitly forbidden by CLAUDE.md).

## Estimated scope

**M.** Roughly 550–750 LOC: ~120 helper-side (tap/framer/encoder glue + ScreenCapture audio output), ~60 wire (both directions + parsing), ~80 server (packetizer, latch, fan-out), ~90 viewer (routing + second player node), ~80 UI/AppState/strings, ~150–250 tests. No dependency, package, or CI-workflow changes.
