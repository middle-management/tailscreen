---
paths:
  - "Packages/TailscaleKit/**"
---

# TailscaleKit (the libtailscale-fork wrapper)

```
Packages/TailscaleKit/
├── upstream/libtailscale/  # Git submodule — OUR FORK (middle-management/libtailscale, branch tailscreen-main)
├── Sources/  lib/  include/  # Symlinks into the submodule
├── Modules/libtailscale/   # Module map for the C library
└── libtailscale.pc         # pkg-config file (used via PKG_CONFIG_PATH)
```

## The fork submodule

`Packages/TailscaleKit/upstream/libtailscale` is a submodule of our fork, `middle-management/libtailscale`, branch `tailscreen-main`: upstream `tailscale/libtailscale` history with our changes as ordinary commits on top. After a fresh clone: `git submodule update --init --recursive` (or clone with `--recurse-submodules`).

Those commits are the former `Patches/*.patch` series (subjects match the old filenames; sections below still refer to them by historical patch number). Notable ones: Linux portability (022 — Combine→AsyncStream fallback, Glibc syscall shim, SOCKS-free direct-loopback LocalAPI), short-write-safe `OutgoingConnection.send` (023), the Windows bridge seam (024, below), the Windows Go-runtime start (026, below), a reader actor for `OutgoingConnection.receive` (027 — the blocking `poll(2)` used to run under the connection actor, so a receive with a multi-second timeout held the connection and every concurrent `send` queued behind it — this is why viewer input/annotations reached the sharer seconds late). On top sits the **guest (share-by-token) surface**: a `guest` Go package (per-link ephemeral WireGuard node, `tc…` token mint/parse, DERP bootstrap, peer enumeration + key eviction), wrapped by `Sources/GuestNode.swift` (`GuestServerNode`, `GuestClientNode`). Guest listeners/connections reuse tsnet's Swift types (`PacketListener`, `Listener`, `IncomingConnection`) because guest fds are bit-compatible with tsnet fds — that's what let the app's media and framed-TCP machinery adopt the tunnel unchanged.

**Changing the wrapped sources**: edit through the symlinks (or in the submodule directly), then commit *in the submodule* on `tailscreen-main`, push to the fork, and bump the submodule pointer here — all three steps required; an uncommitted submodule edit is invisible to everyone else, and a bumped pointer to an unpushed commit breaks every clone. Keep upstreamable fixes upstreamable (one logical change per commit). To take new upstream work, fetch and merge in the submodule (never rebase the published branch).

## The Go↔C socket bridge (024, windows-bridge-seam)

`tailscale.go`'s platform seam: tsnet conns are userspace-WireGuard with no OS descriptor, so libtailscale bridges each to a real socket pair for C. Upstream uses `socketpair(2)` + SCM_RIGHTS — neither exists on Windows (`syscall.Socketpair`/`AF_LOCAL` undefined for `GOOS=windows`; Win10 1803+ has AF_UNIX streams but no `socketpair()` and no datagram mode, which the UDP video path needs). Both flavours moved behind `bridge.go`'s `bridgeStream`/`bridgePacket`/`bridgeConnSender` interfaces: `bridge_unix.go` unchanged, `bridge_windows.go` uses loopback TCP/UDP pairs (accept handoff writes the handle *value* directly — same process, one handle table, no SCM_RIGHTS needed).

`syscall.Accept`, `Recvfrom`, `Sendto`, `SetsockoptTimeval` **compile on Windows but are `EWINDOWS` stubs that always fail at runtime** — the Windows accept path must go through Go's `net` package instead. `libtailscale.a` builds for `windows/amd64`, proven by `Build (Windows)`'s `windows-app` job (`tsnet-probe`); a node reaching a real tailnet on Windows is still unproven.

## The Go runtime start on Windows (026, windows-go-runtime-init)

A Go c-archive doesn't start its own runtime: it asks the C runtime to call `_rt0_amd64_windows_lib`, and until that happens every cgo entry point blocks in `_cgo_wait_runtime_init_done` (no timeout, no error, no log line). Go asks via a `.ctors` section (GNU/MinGW convention); Swift on Windows is MSVC, whose CRT walks `.CRT$XCA`…`.CRT$XCZ` and never reads `.ctors` — so the initializer shipped but was never called. Symptom: sign-in froze after two log lines, `GODEBUG=inittrace=1` printed nothing (there was no runtime to trace), and nothing in the build catches it.

Fix: `Sources/CGoRuntimeInit` (C target, no-op off Windows) registers the entry point in `.CRT$XCU` **and** exposes idempotent `ts_go_runtime_start()`, called from `TailscaleNode.init` before `tailscale_new()` — belt (section entry for correct timing) and suspenders (explicit call guarantees the object is linked and the runtime starts). Windows CI runs `tsnet-probe` and fails if node creation doesn't return.

## Linux

TailscaleKit builds and passes its tests on Linux (Go c-archive + Swift wrapper; CI job `linux-tailscalekit`). Live two-node tsnet exchange (TCP + UDP `PacketListener` + LocalAPI over local headscale via `scripts/e2e-up-native.sh`) verified manually — see `plans/porting-plan.md` Phase 1.
