# Patches for Upstream TailscaleKit

This directory contains patches that fix bugs or add necessary changes to the upstream TailscaleKit Swift sources.

## How it Works

- **Patches are automatically applied** before building via the Makefile
- The `.patches-applied` marker file tracks whether patches have been applied
- Patches are applied to `upstream/libtailscale/swift/TailscaleKit/` (which is symlinked to `Sources/TailscaleKit`)

## Managing Patches

### Apply patches manually:
```bash
make apply-patches
```

### Revert patches:
```bash
make unapply-patches
```

### Clean build (also reverts patches):
```bash
make clean
```

## What the patches do

Each patch file is named for what it does; the rationale and any subtlety
lives in the patch's diff comments. (Numbering note: the series jumps
008 → 012 — git history shows numbers 009-011 were never used by any
patch. Gaps are harmless: patches apply in filename order and nothing
references the numbers.) The categories of patches we carry:

- A `Foundation` import that upstream forgets in some files.
- Glue `import libtailscale` lines for the C-bridge types in the upstream
  Swift sources (Swift Package Manager needs them; upstream's Xcode build
  doesn't).
- `send`/`receive` on connections.
- A public `logout`.
- Listener poll-timeout handling.
- A `tsnet ListenPacket` exported function (Go) plus the matching C glue
  and a Swift `PacketListener` actor — the UDP transport used by the RTP
  video path. Upstream `tsnet.Server.Listen` is TCP-only.
- A close-path fix for the same `PacketListener`: closing via
  `Darwin.close(fd)` doesn't reliably unblock the bridge goroutine on
  macOS for SOCK_DGRAM unix-socket pairs, leaving the netstack port
  bound. The patch promotes a `closeOnce` and exports a dedicated close
  function that owns teardown of both ends.
- A short-write-safe `OutgoingConnection.send` (`023`): upstream did a
  single `write(2)` and threw `shortWrite` on partial writes (socketpair
  buffers are a few KB, so large frames legitimately short-write);
  the patch loops like `IncomingConnection.send` already did. Replaced
  the app-side `Mirror`-over-private-fd extension that papered over it.
- Linux portability (`022`): `#if canImport(...)` gates so the wrapper
  builds on Linux — Combine state publishers get an `AsyncStream`
  fallback, the `Darwin.`-qualified syscalls get a Glibc shim, URLSession
  types import `FoundationNetworking`, the Network.framework SOCKS
  `ProxyConfiguration` extension compiles out, and `LocalAPIClient` talks
  to the tsnet loopback listener directly (plain HTTP + the same auth
  headers) instead of through the SOCKS hop. Verified live on Linux:
  two tsnet nodes over local headscale exchanging TCP, UDP
  (`PacketListener`), and LocalAPI status.

## Patch hygiene (learned the hard way)

- **A patch must be a sequential diff against the stack before it**, never
  against pristine upstream. Patch 021 originally carried a stale hunk
  that re-added the whole `TsnetListenPacket` block 013/017 already
  install: BSD `patch` (macOS) rejected the hunk invisibly behind the
  loop's old `|| true`, while GNU `patch` (Linux) fuzz-fitted it and
  produced duplicate Go functions that broke the c-archive build. The
  Makefile now hard-fails on any reject — if your new patch trips it,
  regenerate it from a fully-patched tree.

## Creating New Patches

1. Make your changes to files in `upstream/libtailscale/swift/TailscaleKit/`
2. Generate a patch:
   ```bash
   git -C upstream/libtailscale diff swift/TailscaleKit/YourFile.swift > Patches/NNN-description.patch
   ```
3. Edit the patch to use the correct path (should start with `a/upstream/libtailscale/`)
4. Test the patch:
   ```bash
   make unapply-patches
   make apply-patches
   ```
