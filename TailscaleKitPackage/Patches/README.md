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
lives in the patch's diff comments. The categories of patches we carry:

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
