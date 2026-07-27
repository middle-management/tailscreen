//go:build windows

package main

import (
	"bytes"
	"encoding/binary"
	"math"
	"syscall"
	"testing"
	"time"
)

// Leg A of the spike: the bridge primitives, provable without any C toolchain.
// Leg B (harness.c) proves the same handle works from real C recv().

// The stream path — what tailscale_dial / tailscale_accept hand back as a
// tailscale_conn. Go writes, the native end reads with the same Winsock call C
// would make.
func TestStreamPairRoundTrip(t *testing.T) {
	p, err := NewStreamPair()
	if err != nil {
		t.Fatalf("NewStreamPair: %v", err)
	}
	defer p.Close()

	want := []byte("HELLO from the Go side of the bridge")
	go func() {
		if _, err := p.Go.Write(want); err != nil {
			t.Errorf("go-side write: %v", err)
		}
	}()

	got := make([]byte, len(want))
	read := 0
	for read < len(want) {
		n, err := recvNative(p.Native, got[read:])
		if err != nil {
			t.Fatalf("native recv: %v", err)
		}
		if n == 0 {
			t.Fatal("native recv returned 0 bytes (peer closed early)")
		}
		read += n
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("native end read %q, want %q", got, want)
	}
}

// And the reverse direction, since the bridge is bidirectional: a viewer sends
// NACK/RR/PLI back over the same conn it receives on.
func TestStreamPairReverseDirection(t *testing.T) {
	p, err := NewStreamPair()
	if err != nil {
		t.Fatalf("NewStreamPair: %v", err)
	}
	defer p.Close()

	want := []byte("feedback from the native side")
	if _, err := sendNative(p.Native, want); err != nil {
		t.Fatalf("native send: %v", err)
	}

	if err := p.Go.SetReadDeadline(time.Now().Add(10 * time.Second)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}
	got := make([]byte, len(want))
	if _, err := p.Go.Read(got); err != nil {
		t.Fatalf("go-side read: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("go end read %q, want %q", got, want)
	}
}

// THE load-bearing test. Patch 013's UDP path assumes one datagram in produces
// exactly one datagram out — RTP depends on it, and a stream socket would
// silently coalesce, tearing frames in a way that only shows up under load.
// AF_UNIX on Windows cannot do SOCK_DGRAM at all, so this asserts the loopback
// UDP replacement preserves boundaries.
func TestPacketPairPreservesDatagramBoundaries(t *testing.T) {
	p, err := NewPacketPair()
	if err != nil {
		t.Fatalf("NewPacketPair: %v", err)
	}
	defer p.Close()

	// Deliberately varied sizes, including two in a row that a stream socket
	// would happily merge into one read.
	payloads := [][]byte{
		bytes.Repeat([]byte{0xA1}, 1),
		bytes.Repeat([]byte{0xB2}, 1200),
		bytes.Repeat([]byte{0xC3}, 7),
		bytes.Repeat([]byte{0xD4}, 8),
	}

	for _, pl := range payloads {
		if _, err := p.Go.WriteTo(pl, p.NativeAddr); err != nil {
			t.Fatalf("go-side WriteTo: %v", err)
		}
	}

	for i, want := range payloads {
		// A buffer far larger than any single payload: if boundaries were lost,
		// one recv would return several payloads concatenated and the length
		// check below would catch it.
		buf := make([]byte, 4096)
		n, err := recvNative(p.Native, buf)
		if err != nil {
			t.Fatalf("datagram %d: native recv: %v", i, err)
		}
		if n != len(want) {
			t.Fatalf("datagram %d: got %d bytes, want exactly %d — message boundary not preserved",
				i, n, len(want))
		}
		if !bytes.Equal(buf[:n], want) {
			t.Fatalf("datagram %d: payload mismatch", i)
		}
	}
}

// The C API types a connection as `int` (tailscale_conn), but a Windows SOCKET
// is UINT_PTR — 64 bits on win/amd64. Microsoft documents handle values as
// 32-bit-significant, but "documented" and "true on this runner" are different
// claims, so assert it rather than trusting it. If this ever fails, the C API
// needs a wider type and every caller changes.
func TestNativeHandleFitsInCInt(t *testing.T) {
	var handles []syscall.Handle
	var closers []func()
	defer func() {
		for _, c := range closers {
			c()
		}
	}()

	// Several pairs, so we exercise more than the first handle the process is
	// ever handed.
	for i := 0; i < 8; i++ {
		p, err := NewStreamPair()
		if err != nil {
			t.Fatalf("pair %d: %v", i, err)
		}
		closers = append(closers, p.Close)
		handles = append(handles, p.Native)
	}

	for i, h := range handles {
		if uintptr(h) > math.MaxInt32 {
			t.Fatalf("handle %d is %#x, which does not fit in a C int — "+
				"tailscale_conn would truncate it", i, uintptr(h))
		}
		if syscall.Handle(int32(h)) != h {
			t.Fatalf("handle %d does not round-trip through int32", i)
		}
	}
}

// The accept path on Unix passes the accepted descriptor with
// syscall.Sendmsg + syscall.UnixRights — SCM_RIGHTS, which Windows has no
// equivalent for at all. This proves none is needed: the Go and native sides
// live in the same process and therefore the same handle table, so the handle
// *value* can simply be written down the control channel. The elaborate Unix
// machinery exists for a constraint we do not have.
func TestAcceptHandoffWithoutSCMRights(t *testing.T) {
	control, err := NewStreamPair()
	if err != nil {
		t.Fatalf("control pair: %v", err)
	}
	defer control.Close()

	conn, err := NewStreamPair()
	if err != nil {
		t.Fatalf("conn pair: %v", err)
	}
	defer conn.Close()

	// Go side announces the accepted connection by value, the way TsnetAccept
	// would once ported.
	go func() {
		var msg [4]byte
		binary.LittleEndian.PutUint32(msg[:], uint32(conn.Native))
		if _, err := control.Go.Write(msg[:]); err != nil {
			t.Errorf("control write: %v", err)
		}
	}()

	var msg [4]byte
	read := 0
	for read < len(msg) {
		n, err := recvNative(control.Native, msg[read:])
		if err != nil {
			t.Fatalf("control recv: %v", err)
		}
		read += n
	}
	handed := syscall.Handle(binary.LittleEndian.Uint32(msg[:]))
	if handed != conn.Native {
		t.Fatalf("handed handle %#x != original %#x", uintptr(handed), uintptr(conn.Native))
	}

	// And the handed-over handle is genuinely usable, not just numerically
	// equal — write on the Go end of that pair, read via the received handle.
	want := []byte("payload over the handed-over handle")
	go func() {
		if _, err := conn.Go.Write(want); err != nil {
			t.Errorf("conn write: %v", err)
		}
	}()

	got := make([]byte, len(want))
	read = 0
	for read < len(want) {
		n, err := recvNative(handed, got[read:])
		if err != nil {
			t.Fatalf("recv on handed handle: %v", err)
		}
		read += n
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("read %q over handed handle, want %q", got, want)
	}
}

// Closing the Go end must surface to the native end as EOF (recv returning 0),
// which is how the Swift wrapper detects a dropped connection today.
func TestGoSideCloseIsVisibleAsEOF(t *testing.T) {
	p, err := NewStreamPair()
	if err != nil {
		t.Fatalf("NewStreamPair: %v", err)
	}
	defer p.Close()

	p.Go.Close()

	buf := make([]byte, 64)
	n, err := recvNative(p.Native, buf)
	if err == nil && n == 0 {
		return // graceful EOF
	}
	// A reset (WSAECONNRESET) is also an acceptable, detectable close; a
	// successful read of real bytes is not.
	if err != nil {
		return
	}
	t.Fatalf("native recv returned %d bytes after the Go end closed", n)
}
