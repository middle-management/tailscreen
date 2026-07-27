//go:build windows && cgo

// Leg B of the spike: the same primitives exposed across a real cgo c-archive
// boundary, so `harness.c` can prove that plain C recv() works on the handle
// Go hands over — which is exactly the contract libtailscale's C API makes and
// the Swift wrapper consumes.
//
// Leg A (pair_test.go) reads the native end from Go using the same Winsock
// calls C would. That is strong evidence but not proof: it never crosses the
// language boundary, and a c-archive is where linkage and runtime-init
// surprises live. This file closes that gap.
package main

import "C"

import (
	"bytes"
	"sync"
	"unsafe"
)

// streamPayload is the byte pattern the Go side writes for the C harness to
// verify. Exported through SpikeStreamPayload so the literal lives in exactly
// one place.
var streamPayload = []byte("HELLO from the Go side of the bridge")

// packetSizes are the datagram lengths the Go side sends, chosen so that a
// stream socket masquerading as a datagram one would be caught: the last two
// are small and adjacent, and would coalesce.
var packetSizes = []int{1, 1200, 7, 8}

// Pairs must outlive the exported call that created them — the C side keeps
// using the handle after the function returns, and nothing else references the
// Go end, so without this the net.Conn becomes garbage and its finalizer
// closes the socket underneath the C caller.
var live struct {
	sync.Mutex
	streams []*StreamPair
	packets []*PacketPair
}

// Creates a connected stream pair, writes streamPayload from the Go end, and
// returns the native end as the `int` the C API would call a tailscale_conn.
// Returns -1 on failure.
//
//export SpikeStreamPair
func SpikeStreamPair() C.int {
	p, err := NewStreamPair()
	if err != nil {
		return -1
	}

	live.Lock()
	live.streams = append(live.streams, p)
	live.Unlock()

	go p.Go.Write(streamPayload)

	return C.int(int32(p.Native))
}

// Length of the payload SpikeStreamPair writes.
//
//export SpikeStreamPayloadLen
func SpikeStreamPayloadLen() C.int {
	return C.int(len(streamPayload))
}

// Compares n bytes at buf against the expected payload, so the C harness never
// has to restate the literal. Returns 1 on match.
//
//export SpikeStreamPayloadMatches
func SpikeStreamPayloadMatches(buf unsafe.Pointer, n C.int) C.int {
	if int(n) != len(streamPayload) {
		return 0
	}
	got := C.GoBytes(buf, n)
	if bytes.Equal(got, streamPayload) {
		return 1
	}
	return 0
}

// Creates a connected datagram pair, sends len(packetSizes) datagrams from the
// Go end, and returns the native end. Returns -1 on failure.
//
//export SpikePacketPair
func SpikePacketPair() C.int {
	p, err := NewPacketPair()
	if err != nil {
		return -1
	}

	live.Lock()
	live.packets = append(live.packets, p)
	live.Unlock()

	go func() {
		for i, size := range packetSizes {
			// Fill each datagram with its index so a mis-ordered or merged
			// read is identifiable, not just a length mismatch.
			buf := bytes.Repeat([]byte{byte(i + 1)}, size)
			if _, err := p.Go.WriteTo(buf, p.NativeAddr); err != nil {
				return
			}
		}
	}()

	return C.int(int32(p.Native))
}

// How many datagrams SpikePacketPair sends.
//
//export SpikePacketCount
func SpikePacketCount() C.int {
	return C.int(len(packetSizes))
}

// Expected length of the i-th datagram, or -1 if i is out of range.
//
//export SpikePacketSizeAt
func SpikePacketSizeAt(i C.int) C.int {
	if int(i) < 0 || int(i) >= len(packetSizes) {
		return -1
	}
	return C.int(packetSizes[i])
}
