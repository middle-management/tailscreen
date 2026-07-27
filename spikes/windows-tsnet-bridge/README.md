# Spike: the Windows Go↔native bridge

**Question this answers:** can libtailscale's Go↔native bridge be rebuilt on
Windows primitives while keeping the existing C API shape — an `int` that
native code `recv()`s and `send()`s on?

This is the one risk that could invalidate the whole shape of a Windows port,
so it gets retired first, before any UI work. Deliberately **no tsnet**: the
spike isolates the bridge primitives so a failure points at the primitive, not
at forty layers of Tailscale.

## Why the bridge is the problem

`docs/viewer-windows-plan.md` used to say the Windows toolchain work was "build
`libtailscale.a` for Windows — add a `windows/amd64` target". That is wrong, and
here is the measurement:

- Go itself is fine. It accepts `-buildmode=c-archive` for `windows/amd64` and
  resolves the whole Windows Tailscale dependency set (wintun, wingoes,
  certstore, go-winio).
- `tailscale.c` includes `<sys/socket.h>` and `<unistd.h>` but never uses
  them — cosmetic.
- **`tailscale.go` is not cosmetic.** Its entire Go↔native handoff rests on
  `syscall.Socketpair(AF_LOCAL, …)` plus `syscall.Sendmsg` +
  `syscall.UnixRights` — SCM_RIGHTS descriptor passing — and
  `golang.org/x/sys/unix`. 19 call sites across 828 lines.

`syscall.Socketpair` and `syscall.AF_LOCAL` are **undefined** for
`GOOS=windows`. Win10 1803+ has AF_UNIX *stream* sockets but no `socketpair()`
and no AF_UNIX datagram mode at all — and our own
`Patches/013-add-tsnet-listen-packet-go.patch`, the UDP path carrying all
video, uses a `SOCK_DGRAM` socketpair.

### A trap worth knowing about

Several Winsock wrappers in Go's `syscall` package **compile on Windows but are
`EWINDOWS` stubs that always fail at runtime**: `Accept`, `Recvfrom`, `Sendto`,
`SetsockoptTimeval`. `Socket`, `Bind`, `Listen`, `Connect`, `Getsockname`,
`Closesocket`, `WSARecv` and `WSASend` are real. A port written against the
compiler's opinion alone would build cleanly and then fail on first use.

## What the spike builds

Loopback-socket replacements for both socketpair flavours (`pair_windows.go`):

| Unix primitive | Windows replacement |
|---|---|
| `socketpair(AF_LOCAL, SOCK_STREAM)` | listen on `127.0.0.1:0` → connect → accept → drop listener |
| `socketpair(AF_LOCAL, SOCK_DGRAM)` | two UDP sockets, each `connect`ed to the other |
| `Sendmsg` + `UnixRights` (SCM_RIGHTS) | write the handle *value* down the control channel |

That last row is the interesting one. The Unix code passes descriptors between
processes because that is what SCM_RIGHTS is for — but Go and the native code
here are **in the same process**, sharing one handle table, so the value is
enough. The elaborate machinery exists for a constraint we do not have.

The accept side goes through Go's `net` package (which uses `AcceptEx`
internally and works) while only the native-side socket is created with raw
syscalls. That sidesteps the `Accept` stub, and it makes the Go end an
idiomatic poller-managed `net.Conn` — *better* than the Unix implementation,
which pumps its end with raw `syscall.Read` on a dedicated OS thread and
carries a TODO asking whether `os.NewFile` would avoid the locked-up thread.

## The two legs

**Leg A — `pair_test.go`**, pure Go, no C toolchain needed:

- stream round trip, both directions
- **datagram boundaries preserved** — the load-bearing one for patch 013: one
  datagram in must produce exactly one out, or RTP tears under load in a way no
  smoke test would catch
- native handle fits in a C `int` — `SOCKET` is `UINT_PTR`, 64-bit on win/amd64,
  while `tailscale_conn` is `int`. Microsoft documents handle values as
  32-bit-significant; this asserts it rather than trusting it
- accept handoff without SCM_RIGHTS, including that the handed-over handle is
  genuinely usable and not merely numerically equal
- closing the Go end surfaces to the native end as EOF

**Leg B — `harness.c`**, across a real cgo c-archive boundary: plain C `recv()`
on the handle Go handed over, for both stream and datagram. Leg A reads the
native end from Go using the same Winsock calls C would, which is strong
evidence but not proof — it never crosses the language boundary, and a
c-archive is where linkage and runtime-init surprises live.

## Running it

Cross-compile from Linux (proves it builds and links, not that it works):

```bash
sudo apt-get install gcc-mingw-w64-x86-64
./build.sh          # → harness.exe, a PE32+ console executable
```

Actually running it needs Windows. The `windows-spike` CI job
(`.github/workflows/windows-spike.yml`) does both legs on a `windows-latest`
runner. It is **not** a merge gate — it runs on `workflow_dispatch` or the
`run-windows-spike` PR label, the same pattern as the Linux packaging job.

## What this does *not* prove

- Nothing about tsnet. The spike never brings up a node; it proves the
  transport primitives underneath one.
- Nothing about throughput. Loopback TCP/UDP with a Go-side copy has a cost
  that matters at 60fps and is unmeasured here.
- Nothing about the Swift side, which currently `read`/`write`s the descriptor
  and would need `recv`/`send` on Windows (Windows CRT `_read`/`_write` do not
  work on sockets).
- Nothing about the **sharer**. Inbound listeners are a separate question; see
  the SOCKS5 note in `docs/viewer-windows-plan.md`.
