//go:build windows

// Windows replacements for the two Unix primitives libtailscale's Go↔native
// bridge is built on: socketpair(2) and SCM_RIGHTS descriptor passing.
//
// Neither exists on Windows. `syscall.Socketpair` and `syscall.AF_LOCAL` are
// undefined for GOOS=windows outright, and while Win10 1803+ has AF_UNIX
// *stream* sockets, it has no socketpair() and no AF_UNIX datagram mode at all
// — which matters because patch 013 (tsnet ListenPacket, the path carrying all
// video) uses a SOCK_DGRAM socketpair.
//
// A second trap: several Winsock wrappers in Go's syscall package compile on
// Windows but are `EWINDOWS` stubs that always fail at runtime — Accept,
// Recvfrom and Sendto among them. So the accept side here goes through Go's
// `net` package (which uses AcceptEx internally and works), and only the
// native-side socket is created with raw syscalls. That split is deliberate,
// not incidental: it keeps the Go end an idiomatic net.Conn while the native
// end stays a plain blocking SOCKET that C can recv() on.
//
// The result is actually *simpler* than the Unix implementation, which pumps
// its Go end with raw syscall.Read on a dedicated OS thread and carries a TODO
// asking whether os.NewFile would avoid the locked-up thread. Here the Go end
// is poller-managed for free.
package main

import (
	"fmt"
	"net"
	"syscall"
)

func main() {}

// StreamPair is a connected pair of stream sockets: `Go` is the end this
// process's Go code talks to, `Native` is the raw handle handed across the C
// API boundary — the stand-in for what `tailscale_dial` / `tailscale_accept`
// return as a `tailscale_conn`.
type StreamPair struct {
	Go     net.Conn
	Native syscall.Handle
}

// Close releases both ends. Safe to call with a partially constructed pair.
func (p *StreamPair) Close() {
	if p == nil {
		return
	}
	if p.Go != nil {
		p.Go.Close()
	}
	if p.Native != 0 {
		syscall.Closesocket(p.Native)
	}
}

// NewStreamPair emulates socketpair(AF_LOCAL, SOCK_STREAM) with the standard
// loopback dance: listen on 127.0.0.1:0, connect to it, accept, drop the
// listener. Loopback TCP rather than AF_UNIX because AF_UNIX on Windows cannot
// do datagrams (see NewPacketPair) and using one transport for both keeps the
// bridge uniform.
func NewStreamPair() (*StreamPair, error) {
	// tcp4 explicitly: on a dual-stack host "tcp" can bind ::1, and the raw
	// AF_INET socket below could then never reach it.
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("listen: %w", err)
	}
	defer l.Close()

	addr, ok := l.Addr().(*net.TCPAddr)
	if !ok {
		return nil, fmt.Errorf("listener address is %T, want *net.TCPAddr", l.Addr())
	}

	native, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_STREAM, 0)
	if err != nil {
		return nil, fmt.Errorf("socket: %w", err)
	}

	// Accept concurrently with connect. On loopback the connect would normally
	// complete into the backlog without an accept, but ordering the two this
	// way avoids depending on that.
	type accepted struct {
		conn net.Conn
		err  error
	}
	acceptCh := make(chan accepted, 1)
	go func() {
		c, err := l.Accept()
		acceptCh <- accepted{c, err}
	}()

	sa := &syscall.SockaddrInet4{Port: addr.Port}
	copy(sa.Addr[:], addr.IP.To4())
	if err := syscall.Connect(native, sa); err != nil {
		syscall.Closesocket(native)
		return nil, fmt.Errorf("connect: %w", err)
	}

	got := <-acceptCh
	if got.err != nil {
		syscall.Closesocket(native)
		return nil, fmt.Errorf("accept: %w", got.err)
	}

	return &StreamPair{Go: got.conn, Native: native}, nil
}

// PacketPair is the datagram counterpart — the replacement for the
// SOCK_DGRAM socketpair patch 013 uses to carry UDP between tsnet and native
// code. Message boundaries must survive, since the RTP path depends on one
// datagram in producing exactly one datagram out.
//
// Built from two connected UDP sockets rather than a stream: connect(2) on a
// UDP socket fixes its peer, so the native end can use plain blocking recv()
// and still get one datagram per call.
type PacketPair struct {
	Go     net.PacketConn
	Native syscall.Handle
	// NativeAddr is where the Go end writes to reach the native end.
	NativeAddr net.Addr
}

// Close releases both ends. Safe to call with a partially constructed pair.
func (p *PacketPair) Close() {
	if p == nil {
		return
	}
	if p.Go != nil {
		p.Go.Close()
	}
	if p.Native != 0 {
		syscall.Closesocket(p.Native)
	}
}

// NewPacketPair emulates socketpair(AF_LOCAL, SOCK_DGRAM).
func NewPacketPair() (*PacketPair, error) {
	goSide, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("listenpacket: %w", err)
	}

	goAddr, ok := goSide.LocalAddr().(*net.UDPAddr)
	if !ok {
		goSide.Close()
		return nil, fmt.Errorf("go-side address is %T, want *net.UDPAddr", goSide.LocalAddr())
	}

	native, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0)
	if err != nil {
		goSide.Close()
		return nil, fmt.Errorf("socket: %w", err)
	}

	bindTo := &syscall.SockaddrInet4{Port: 0, Addr: [4]byte{127, 0, 0, 1}}
	if err := syscall.Bind(native, bindTo); err != nil {
		goSide.Close()
		syscall.Closesocket(native)
		return nil, fmt.Errorf("bind: %w", err)
	}

	// Connect the native end to the Go end so recv() works unqualified and
	// stray datagrams from anywhere else are dropped by the kernel.
	peer := &syscall.SockaddrInet4{Port: goAddr.Port}
	copy(peer.Addr[:], goAddr.IP.To4())
	if err := syscall.Connect(native, peer); err != nil {
		goSide.Close()
		syscall.Closesocket(native)
		return nil, fmt.Errorf("connect: %w", err)
	}

	// Getsockname after bind+connect so the ephemeral port is resolved.
	nsa, err := syscall.Getsockname(native)
	if err != nil {
		goSide.Close()
		syscall.Closesocket(native)
		return nil, fmt.Errorf("getsockname: %w", err)
	}
	n4, ok := nsa.(*syscall.SockaddrInet4)
	if !ok {
		goSide.Close()
		syscall.Closesocket(native)
		return nil, fmt.Errorf("native address is %T, want *syscall.SockaddrInet4", nsa)
	}

	return &PacketPair{
		Go:         goSide,
		Native:     native,
		NativeAddr: &net.UDPAddr{IP: net.IP(n4.Addr[:]).To4(), Port: n4.Port},
	}, nil
}

// recvNative reads from a raw native handle the way C's recv() would, using
// WSARecv — which, unlike syscall.Recv (absent) or syscall.Recvfrom (an
// EWINDOWS stub), is a real call on Windows.
func recvNative(h syscall.Handle, buf []byte) (int, error) {
	if len(buf) == 0 {
		return 0, nil
	}
	wsaBuf := syscall.WSABuf{Len: uint32(len(buf)), Buf: &buf[0]}
	var n, flags uint32
	if err := syscall.WSARecv(h, &wsaBuf, 1, &n, &flags, nil, nil); err != nil {
		return 0, err
	}
	return int(n), nil
}

// sendNative writes to a raw native handle the way C's send() would.
func sendNative(h syscall.Handle, buf []byte) (int, error) {
	if len(buf) == 0 {
		return 0, nil
	}
	wsaBuf := syscall.WSABuf{Len: uint32(len(buf)), Buf: &buf[0]}
	var n uint32
	if err := syscall.WSASend(h, &wsaBuf, 1, &n, 0, nil, nil); err != nil {
		return 0, err
	}
	return int(n), nil
}
