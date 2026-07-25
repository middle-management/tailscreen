// The wire protocol, pure decision logic, tsnet transport layer, Opus
// codec, and the host-agnostic sharer data plane live in the local
// TailscreenKit (they also build on Linux — see its README). Re-export those
// products so the rest of the app keeps referring to their types unqualified,
// exactly as when they compiled in-module. TailscreenAudio re-exports OpusKit, so `Opus.Application`
// is visible unqualified too. (Sorted lexicographically for OrderedImports.)
@_exported import TailscreenAudio
@_exported import TailscreenProtocol
@_exported import TailscreenSharer
@_exported import TailscreenTransport
