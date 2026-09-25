# Share system/computer audio to viewers

> Status: shipped. Sharer can toggle "Share System Audio"; viewers hear it
> mixed alongside voice chat. macOS-only (system-audio capture is a
> ScreenCaptureKit facility; per `CLAUDE.md` this is one of the named
> macOS-only capabilities).

## Problem

Viewers saw the sharer's screen but heard nothing the Mac was playing (voice
chat is mic↔mic only). ScreenCaptureKit can deliver system audio from the
same `SCStream` already capturing video, and the app already has a complete
AAC/RTP audio transport for voice — the work was plumbing captured system
audio through the existing helper wire and UDP/7447 fan-out, tagged so
viewers can demux it from voice without any negotiation.

## Key design decisions

- **New RTP payload type 99 + reserved SSRC 1**, same auto-detect philosophy
  as video's PT 96/97 — no capability negotiation needed. Viewer/voice SSRCs
  were bumped to start at 2 to keep the space disjoint (both video and audio
  ranges, for uniformity, even though only audio strictly needed it).
- **Helper always captures system audio into the pipe; a live latch gates
  emission, not capture.** The original plan tied the SCStream's audio output
  to whether the share *started* with audio enabled — but that makes the
  menubar toggle dead mid-share (turning it on would need a helper respawn).
  Shipped instead: the audio output is always configured when the picker
  selection carries the field, and a `setAudioEnabled` latch (mirroring
  `forceH264`) gates whether AUs actually leave the helper — instant
  mute/unmute, no respawn, same privacy posture as video (always captured
  into the helper, never sent unless enabled). The latch is re-sent after
  every helper (re)spawn, same as `forceH264`.
- **Encoding happens in the helper, not the parent** — SCStream lifecycle
  must stay in the child (repo-wide rule), and encoding beside it keeps pipe
  traffic tiny (~170B AUs at ~47Hz vs. 192KB/s raw PCM) and reuses `AACEncoder`
  verbatim.
- **Echo avoidance is `excludesCurrentProcessAudio = true`** on the capture
  config — this drops Tailscreen's own output (viewer voices played back
  locally) from the captured mix, so viewer speech is never re-broadcast as
  system audio. The sharer's own mic-side echo cancellation does *not* cover
  this path (system-wide capture, not mic) — this is the only thing that does.
- **Dedicated second `AVAudioPlayerNode` for system audio on the viewer**, not
  funneled into the voice player. Two independent ~50Hz PCM streams scheduled
  into one node **time-multiplex rather than mix** — this is load-bearing,
  not cosmetic; `mainMixerNode` correctly sums two separate nodes. Playing it
  through the engine (rather than a separate output) also keeps VPIO AEC's
  reference signal correct when the viewer's own mic is live.
- **System-audio decode skips the voice jitter/concealment pipeline** — it's
  queue-paced only, since the voice-tuned concealment/jitter estimator has no
  reason to apply to a disjoint SSRC space; a smaller, lower-risk path than
  routing PT 99 through the full voice state machine.
- **Separate `AudioStreamOutput`, not extended into the existing video
  `StreamOutput`.** The video object's counters are lock-free specifically
  because they're touched from one serial queue only; adding an audio queue
  into the same object would race them.
- **Old viewers stay safe with no changes**: PT 99 fails the PT-98-only
  check and `MultiCodecDepacketizer.ingest` returns nil for unknown PTs, so
  a pre-feature viewer just silently drops the packets (small wasted
  downstream bandwidth, no negotiation needed).
- **Inbound anti-spoof needs no new gate**: the server already only accepts
  PT 98 from viewers, so a viewer can never inject PT 99 — that single
  existing check doubles as the system-audio spoof guard.

## Non-goals (kept)

Stereo (v1 is mono 48kHz AAC-LC like voice, reusing `AACDecoder` unchanged —
stereo needs a second decoder config/cookie); per-app audio filtering;
viewer-side volume slider; HELLO capability negotiation (PT auto-detect makes
it unnecessary).

## Pointers

- Wire constants: PT 99 (`RTPHeader.systemAudioPayloadType`), SSRC 1
  (`RTPHeader.systemAudioSSRC`) in `RTPPacket.swift`/`RTPAudio.swift`; helper
  wire `OutType.audioAccessUnit = 0x07`, `InType.setAudioEnabled = 0x04` in
  `CaptureHelperWire.swift`. Full framing in `.claude/rules/protocol.md`.
- Capture/tap: `Apps/macOS/Sources/SystemAudioTap.swift` (pure
  `SystemAudioFramer` + CMSampleBuffer→AAC glue), `ScreenCapture.swift`
  (`capturesAudio`, `AudioStreamOutput`).
- Server: `broadcastSystemAudio` (reuses `sendAudioRTP`'s fan-out chaining)
  and the `shareSystemAudio` latch in `TailscaleScreenShareServer.swift`.
- Viewer: PT routing in `VoiceChannel.swift` (`audioRoute(payloadType:)`,
  `processSystemAudioInbound`, `onSystemAudioPCM` wired in `MicCapture.init`
  next to `onMixedPCM`), widened PT check in `TailscaleScreenShareClient.swift`.
- UI: SharingCard speaker button (`MenuBarView.swift`), default toggle
  (`SettingsView.swift`), `AppState.swift` (`isSystemAudioOn`,
  `SystemAudioDefaults`).
- Tests: `SystemAudioFramerTests`, `SystemAudioRoutingTests`,
  `RTPAudioTests`/`CaptureHelperWireTests` extensions (all CI-able, pure);
  `ScreenShareFanoutTests`/`ScreenShareCaptureHelperTests` extensions
  (local-only, need a real display/audio stack).

## Risks still worth remembering

- All SCK stays in the helper — the parent must only ever see AAC bytes on
  the pipe, never `SCShareableContent`/`SCStream` itself.
- Helper crash-restart must re-send the `setAudioEnabled` latch and must
  carry `captureAudio` in the respawned `PickerSelection` JSON, or a mid-share
  crash silently drops audio or resurrects a muted stream.
- SSRC discipline (sharer voice = 0, system = 1, viewers ≥ 2) is
  load-bearing for both the loopback-drop logic and the server's anti-spoof
  gate — don't renumber.
- `CMSampleBuffer`/its extracted PCM must be pulled into a plain `[Float]`
  before crossing any actor boundary (not `Sendable`).
