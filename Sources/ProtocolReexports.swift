// The wire protocol, pure decision logic, and tsnet transport layer live in
// the local TailscreenProtocolPackage (they also build on Linux — see its
// README). Re-export both products so the rest of the app keeps referring
// to their types unqualified, exactly as when they compiled in-module.
@_exported import TailscreenProtocol
@_exported import TailscreenTransport
// The Opus codec tier (OpusVoiceEncoder / OpusVoiceDecoder / OpusPCM). It
// re-exports OpusKit, so `Opus.Application` is visible unqualified too.
@_exported import TailscreenAudio
