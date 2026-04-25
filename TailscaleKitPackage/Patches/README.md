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

## Current Patches

### 001-add-foundation-import.patch
**Issue:** Upstream's `URLSession+Tailscale.swift` is missing `import Foundation`, causing compilation errors.

**Fix:** Adds `import Foundation` to make `URLSessionConfiguration` available.

**Status:** Should be submitted as a PR to upstream libtailscale.

### 002-add-libtailscale-import-tailscalenode.patch
**Issue:** `TailscaleNode.swift` doesn't import the `libtailscale` C module, causing "cannot find 'tailscale_*'" errors.

**Fix:** Adds `import libtailscale` to make C functions visible to Swift.

**Status:** Required for Swift Package Manager builds; upstream uses Xcode which may handle this differently.

### 003-add-libtailscale-import-listener.patch
**Issue:** `Listener.swift` doesn't import the `libtailscale` C module.

**Fix:** Adds `import libtailscale`.

**Status:** Required for Swift Package Manager builds.

### 004-add-libtailscale-import-outgoingconnection.patch
**Issue:** `OutgoingConnection.swift` doesn't import the `libtailscale` C module.

**Fix:** Adds `import libtailscale`.

**Status:** Required for Swift Package Manager builds.

### 005-add-libtailscale-import-tailscaleerror.patch
**Issue:** `TailscaleError.swift` doesn't import the `libtailscale` C module.

**Fix:** Adds `import libtailscale`.

**Status:** Required for Swift Package Manager builds.

### 009/010/011 (deleted)
Previously swapped `unistd.read/write/close` → `Darwin.read/write/close` in the upstream Swift sources to fix Swift 6 module resolution. Upstream has since adopted the same fix in `main`; the standalone swap patches are no-ops and were removed. Patches 006/007 (which add new functions) now use `Darwin.*` directly.

### 013-add-tsnet-listen-packet-go.patch
**Issue:** libtailscale upstream only exposes `tsnet.Server.Listen` (TCP). Go's `net.Listen` has no UDP variant, so `Listener(proto: .udp)` in the Swift wrapper fails at runtime.

**Fix:** Adds a new `TsnetListenPacket` exported function that wraps `tsnet.Server.ListenPacket`. Bridges the Go `net.PacketConn` to a SOCK_DGRAM socketpair fd. Each datagram on the wire is framed as `[1B addr_len][addr_bytes][payload]` so the per-packet source/destination address survives the bridge.

**Status:** Required for the UDP RTP transport. Worth upstreaming once stable.

### 014-add-tailscale-listen-packet-header.patch
**Issue:** Pairs with 013 — exposes the new function in `tailscale.h` so Swift can call it via the `libtailscale` C module.

**Fix:** Adds `extern int tailscale_listen_packet(...)` with documentation of the on-wire framing.

### 015-add-packet-listener-swift.patch
**Issue:** Pairs with 013/014 — adds a Swift wrapper for the new C function.

**Fix:** Creates `swift/TailscaleKit/PacketListener.swift` exposing a `PacketListener` actor with `recv(timeout:)` returning `(Data, sourceAddress)` and `send(_:to:)` taking a destination "ip:port". UDP datagrams in/out via the same fd; demultiplexing by source address is the caller's job.

### 016-add-tailscale-listen-packet-c-glue.patch
**Issue:** Pairs with 013/014 — wires up the C glue layer for `tailscale_listen_packet`.

**Fix:** Adds `extern int TsnetListenPacket(...)` declaration and the `tailscale_listen_packet()` C wrapper in `tailscale.c`.

### 017-add-tsnet-listen-packet-close-go.patch
**Issue:** Closing a `PacketListener` via `Darwin.close(fd)` on the C-side fd does not reliably unblock `syscall.Read(goFd)` on macOS for SOCK_DGRAM unix-socket pairs. The bridge goroutine blocks indefinitely, so the netstack `PacketConn.Close()` is never called, and the port binding is held. Rapid stop→start (e.g. user stops and restarts sharing) sees "netstack: Bind: port is in use".

**Fix:** Promotes `cleanupOnce sync.Once` onto `packetListener` as a `closeOnce()` method, adds `cFd` so the method owns both fd ends, and exports `TsnetListenPacketClose(fdC)`. The new export:
  - Looks up `pl` by `fdC` under the map lock
  - Calls `pl.closeOnce()` which atomically: deletes from map, closes both socketpair fds (unblocking the bridge goroutines), then calls `pc.Close()` outside the lock (synchronously releasing the netstack bind)
  - Returns 0 on success, EBADF if the fd is not live

**Status:** This is the upstream fix for the close-path race; should be upstreamed to tailscale/libtailscale.

### 018-add-tailscale-listen-packet-close-header.patch
**Issue:** Pairs with 017 — exposes the new close function in `tailscale.h`.

**Fix:** Adds `extern int tailscale_listen_packet_close(tailscale_listener fd)` with documentation noting that callers must NOT call `close(2)` on `fd` afterward (Go closes both socketpair ends).

### 019-add-tailscale-listen-packet-close-c-glue.patch
**Issue:** Pairs with 017/018 — wires up the C layer.

**Fix:** Adds `extern int TsnetListenPacketClose(int fd)` declaration and the `tailscale_listen_packet_close()` C wrapper in `tailscale.c`.

### 020-update-packet-listener-use-close-func.patch
**Issue:** Pairs with 017–019 — the Swift `PacketListener` still called `Darwin.close(listener)` which was the buggy path.

**Fix:** Updates `PacketListener.close()` and `deinit` to call `tailscale_listen_packet_close(listener)` instead. The Go side now owns the full teardown of both socketpair fds; Swift must not call `Darwin.close` afterward.

## Creating New Patches

1. Make your changes to files in `upstream/libtailscale/swift/TailscaleKit/`
2. Generate a patch:
   ```bash
   git -C upstream/libtailscale diff swift/TailscaleKit/YourFile.swift > Patches/002-description.patch
   ```
3. Edit the patch to use the correct path (should start with `a/upstream/libtailscale/`)
4. Test the patch:
   ```bash
   make unapply-patches
   make apply-patches
   ```
