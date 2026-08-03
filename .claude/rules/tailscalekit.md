---
paths:
  - "Packages/TailscaleKit/**"
---

# TailscaleKit (the libtailscale wrapper + patch series)

```
Packages/TailscaleKit/
├── upstream/libtailscale/  # Git submodule (tailscale/libtailscale)
├── Sources/  lib/  include/  # Symlinks into upstream
├── Patches/                # .patch files applied to upstream Swift
├── Modules/libtailscale/   # Module map for the C library
└── libtailscale.pc         # pkg-config file (used via PKG_CONFIG_PATH)
```

## Submodule + patches

`Packages/TailscaleKit/upstream/libtailscale` is pinned in `.gitmodules` (`ignore = dirty`). After a fresh clone, run `git submodule update --init --recursive` (or clone with `--recurse-submodules`).

Patches in `Packages/TailscaleKit/Patches/*.patch` are applied on top of the upstream Swift sources. They add things like a `Foundation` import, glue imports for C-bridge types, `send`/`receive` on connections, public `logout`, listener poll-timeout handling, the `tsnet ListenPacket` / `PacketListener` Swift wrapper used by the UDP video path, a short-write-safe `OutgoingConnection.send` loop (patch 023 — replaced the app-side reflection hack that reached the private fd), Linux portability gates (patch 022 — Combine→AsyncStream fallback, Glibc syscall shim, `FoundationNetworking` imports, SOCKS-free direct-loopback LocalAPI), the **Windows bridge seam** (patch 024 — see below), and the **Windows Go-runtime start** (patch 026 — see below).

**Do not edit `Packages/TailscaleKit/Sources/`** — those are symlinks into the upstream submodule. Add or modify a patch instead, then re-run `make tailscale`. A new patch must be a sequential diff against the fully-patched tree (see `Patches/README.md` — the Makefile hard-fails on rejected hunks; `|| true` used to hide them and let GNU patch double-apply).

## The Go↔C socket bridge (patch 024)

The platform seam under `tailscale.go`. tsnet conns are userspace-WireGuard with no OS descriptor, so libtailscale bridges each to a real socket pair and hands C one end. Upstream does that with `socketpair(2)` plus SCM_RIGHTS descriptor passing for accepted connections — **neither exists on Windows** (`syscall.Socketpair`/`AF_LOCAL` are undefined for `GOOS=windows`; Win10 1803+ has AF_UNIX stream sockets but no `socketpair()` and no datagram mode, which patch 013's UDP video path needs). So both flavours moved behind `bridge.go`'s `bridgeStream` / `bridgePacket` / `bridgeConnSender` interfaces, with `bridge_unix.go` (unchanged behaviour) and `bridge_windows.go` (loopback TCP/UDP pairs; the accept handoff writes the handle *value*, since Go and C share one process and one handle table, so SCM_RIGHTS is unnecessary).

Watch out when extending it: `syscall.Accept`, `Recvfrom`, `Sendto` and `SetsockoptTimeval` **compile on Windows but are `EWINDOWS` stubs that always fail at runtime** — which is why the Windows accept goes through Go's `net` package. `libtailscale.a` now builds for `windows/amd64`, proven by the `Windows build / Swift 6.1` job, which builds the c-archive, links it into the app, and runs `tsnet-probe` against it. A node that reaches a real tailnet on Windows is still unproven.

## The Go runtime start on Windows (patch 026)

The other half of making that archive usable. A Go c-archive does not start its own runtime: it asks the C runtime to call `_rt0_amd64_windows_lib`, and until that happens every cgo entry point blocks in `_cgo_wait_runtime_init_done` — no timeout, no error, no log line. Go asks through a **`.ctors`** section (`cmd/link/internal/ld/pe.go`: "addInitArray adds .ctors COFF section"), which is the GNU convention that MinGW's startup objects walk. Swift on Windows is an MSVC toolchain: its CRT walks `.CRT$XCA`…`.CRT$XCZ` and has never read `.ctors`, so the initialiser ships in the executable and is never called. The app froze on Sign in with two log lines and nothing after; `GODEBUG=inittrace=1` printed nothing at all, because there was no runtime to trace. Nothing in the build can catch this — every symbol resolves and the app starts fine.

`Sources/CGoRuntimeInit` (a C target, a no-op everywhere but Windows) registers the entry point in `.CRT$XCU` **and** exposes an idempotent `ts_go_runtime_start()` that patch 026 calls from `TailscaleNode.init` before `tailscale_new()` — the section entry gives Go its documented timing, the explicit call guarantees the object is linked at all and that the runtime is starting regardless. The Windows CI job runs `tsnet-probe` and fails if node creation does not return, so a regression here is a red build rather than a frozen desktop.

## Linux

**TailscaleKit builds and passes its tests on Linux** (Go c-archive + Swift wrapper; CI job `linux-tailscalekit`). The live two-node tsnet exchange (TCP + UDP `PacketListener` + LocalAPI over local headscale via `scripts/e2e-up-native.sh`, which is OS-aware) has been verified manually on a Linux host — see `docs/porting-plan.md` Phase 1.
