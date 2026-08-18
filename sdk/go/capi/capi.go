// Command capi builds libtailscreen.a: the Tailscreen wire protocol as a C
// static library, for callers that are not Go.
//
// It is the same mechanism this repository already uses one floor down —
// libtailscale.a is Go compiled with -buildmode=c-archive and consumed from
// Swift through a systemLibrary target — so a C, C++, Swift, Rust or Zig
// client links this the way TailscaleKit links that one:
//
//	make libtailscreen                    # sdk/go/build/libtailscreen.{a,h}
//	cc app.c sdk/go/build/libtailscreen.a -lpthread -o app
//
// # What it exposes
//
// The codecs, and only the codecs. Everything here is a pure function over
// bytes: nothing opens a socket, starts a goroutine or keeps state between
// calls except the one explicitly handle-based parser (the TCP framer, which
// cannot be stateless because a frame arrives across segments). That makes
// the library safe to call from any thread — parser handles included: each
// handle carries its own lock, so calls on one handle from different threads
// serialize rather than race — and impossible to leak by forgetting to shut
// something down; the only resources are the buffers it returns and the
// parser handles it hands out.
//
// # Memory
//
// Every function that returns bytes returns memory allocated by C malloc,
// which the CALLER frees with tailscreen_free. The Go garbage collector does
// not know about it and will not reclaim it. A returned length of 0 with a
// NULL pointer means the input was rejected; that is not an error condition
// to be handled so much as the protocol's standard answer to a malformed
// datagram, which is to discard it (TS-CTL-002, TS-GEN-022).
//
// The one exception is tailscreen_parser_new / tailscreen_parser_free, whose
// handles index a table inside Go. Free every parser you create; a leaked
// handle keeps its buffered bytes alive for the process's lifetime.
package main

/*
#include <stdlib.h>
#include <stdint.h>

// A buffer this library allocated. Free `data` with tailscreen_free when
// done. `len` is 0 and `data` NULL when the input was rejected.
typedef struct {
	uint8_t *data;
	int      len;
} tailscreen_buf;

// One parsed TCP frame: a message type and its payload. Free `payload` with
// tailscreen_free.
typedef struct {
	uint8_t  type;
	uint8_t *payload;
	int      len;
} tailscreen_frame;
*/
import "C"

import (
	"sync"
	"unsafe"

	"github.com/middle-management/tailscreen/sdk/go/tailscreen"
)

func main() {} // required by -buildmode=c-archive; never called

// ---------------------------------------------------------------------------
// Buffer plumbing
// ---------------------------------------------------------------------------

// goBytes views a caller-owned buffer without copying. The view is valid only
// for the duration of the call, which is why every function that keeps bytes
// past its return copies them first.
func goBytes(data *C.uint8_t, length C.int) []byte {
	if data == nil || length <= 0 {
		return nil
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(data)), int(length))
}

// cBuf copies a Go slice into malloc'd memory the caller owns.
func cBuf(b []byte) C.tailscreen_buf {
	if b == nil {
		return C.tailscreen_buf{data: nil, len: 0}
	}
	// A zero-length success (an empty parity body, an empty payload) still
	// allocates, so that a NULL pointer unambiguously means "rejected".
	out := C.malloc(C.size_t(len(b)) + 1)
	if out == nil {
		return C.tailscreen_buf{data: nil, len: 0}
	}
	if len(b) > 0 {
		copy(unsafe.Slice((*byte)(out), len(b)), b)
	}
	return C.tailscreen_buf{data: (*C.uint8_t)(out), len: C.int(len(b))}
}

func rejected() C.tailscreen_buf { return C.tailscreen_buf{data: nil, len: 0} }

// Frees a buffer returned by this library. Passing NULL is a no-op, and
// passing anything this library did not return is undefined.
//
//export tailscreen_free
func tailscreen_free(data *C.uint8_t) {
	if data != nil {
		C.free(unsafe.Pointer(data))
	}
}

// The revision of the Tailscreen specification this library implements.
//
//export tailscreen_spec_version
func tailscreen_spec_version() C.int { return C.int(tailscreen.SpecVersion) }

// The protocol's provisional default port, for TCP and UDP alike. Not
// IANA-registered; see TS-GEN-016 before hard-coding it anywhere.
//
//export tailscreen_default_port
func tailscreen_default_port() C.int { return C.int(tailscreen.Port) }

// ---------------------------------------------------------------------------
// UDP control plane
// ---------------------------------------------------------------------------

// Demultiplexes an inbound UDP datagram by its first byte: 0 empty, 1 RTP,
// 2 control (TS-GEN-020).
//
//export tailscreen_classify
func tailscreen_classify(data *C.uint8_t, length C.int) C.int {
	switch tailscreen.Classify(goBytes(data, length)) {
	case tailscreen.ClassRTP:
		return 1
	case tailscreen.ClassControl:
		return 2
	default:
		return 0
	}
}

// Encodes a one-byte control datagram of the given type.
//
//export tailscreen_encode_control
func tailscreen_encode_control(kind C.uint8_t) C.tailscreen_buf {
	return cBuf(tailscreen.EncodeControl(tailscreen.ControlKind(kind)))
}

// Reads the message type off a control datagram. Returns -1 for an empty
// datagram or an unassigned byte — both of which the caller must discard
// silently (TS-CTL-002).
//
//export tailscreen_decode_control
func tailscreen_decode_control(data *C.uint8_t, length C.int) C.int {
	kind, ok := tailscreen.DecodeControl(goBytes(data, length))
	if !ok {
		return -1
	}
	return C.int(kind)
}

// Encodes an extended HELLO carrying the viewer's capability bits.
//
//export tailscreen_encode_hello
func tailscreen_encode_hello(caps C.uint8_t) C.tailscreen_buf {
	return cBuf(tailscreen.EncodeHello(tailscreen.Caps(caps)))
}

// Reads the capability byte off a HELLO, returning 0 for the legacy one-byte
// form (TS-CAP-006).
//
//export tailscreen_decode_hello_caps
func tailscreen_decode_hello_caps(data *C.uint8_t, length C.int) C.uint8_t {
	return C.uint8_t(tailscreen.DecodeHelloCaps(goBytes(data, length)))
}

// Encodes an acknowledgement: pass has_caps=0 for the plain five-byte form,
// which is what a viewer that did not advertise capabilities must receive
// (TS-CAP-004).
//
//export tailscreen_encode_hello_ack
func tailscreen_encode_hello_ack(ssrc C.uint32_t, caps C.uint8_t, hasCaps C.int) C.tailscreen_buf {
	if hasCaps == 0 {
		return cBuf(tailscreen.EncodeHelloAck(uint32(ssrc), nil))
	}
	value := tailscreen.Caps(caps)
	return cBuf(tailscreen.EncodeHelloAck(uint32(ssrc), &value))
}

// Parses either acknowledgement form, writing the SSRC and the sharer's
// capabilities through the out-parameters. Returns 0 on a malformed
// datagram, 1 on success. Either out-parameter may be NULL.
//
//export tailscreen_decode_hello_ack
func tailscreen_decode_hello_ack(data *C.uint8_t, length C.int, ssrcOut *C.uint32_t, capsOut *C.uint8_t) C.int {
	ssrc, caps, ok := tailscreen.DecodeHelloAckTolerant(goBytes(data, length))
	if !ok {
		return 0
	}
	if ssrcOut != nil {
		*ssrcOut = C.uint32_t(ssrc)
	}
	if capsOut != nil {
		*capsOut = C.uint8_t(caps)
	}
	return 1
}

// Encodes a NACK from `count` pairs of (pid, blp) read from `pids` and
// `blps`. More than 16 entries are truncated (TS-NCK-001).
//
//export tailscreen_encode_nack
func tailscreen_encode_nack(pids *C.uint16_t, blps *C.uint16_t, count C.int) C.tailscreen_buf {
	if count <= 0 || pids == nil || blps == nil {
		return cBuf(tailscreen.EncodeNACK(nil))
	}
	pidSlice := unsafe.Slice((*uint16)(unsafe.Pointer(pids)), int(count))
	blpSlice := unsafe.Slice((*uint16)(unsafe.Pointer(blps)), int(count))
	entries := make([]tailscreen.NACKEntry, count)
	for i := range entries {
		entries[i] = tailscreen.NACKEntry{PID: pidSlice[i], BLP: blpSlice[i]}
	}
	return cBuf(tailscreen.EncodeNACK(entries))
}

// Parses a NACK into caller-provided arrays, each of at least `capacity`
// entries. Returns the number written, or 0 for a malformed datagram — a
// truncated entry list yields nothing rather than a prefix (TS-NCK-002).
//
//export tailscreen_decode_nack
func tailscreen_decode_nack(data *C.uint8_t, length C.int, pids *C.uint16_t, blps *C.uint16_t, capacity C.int) C.int {
	entries := tailscreen.DecodeNACK(goBytes(data, length))
	if len(entries) == 0 || pids == nil || blps == nil || capacity <= 0 {
		return 0
	}
	if len(entries) > int(capacity) {
		entries = entries[:capacity]
	}
	pidSlice := unsafe.Slice((*uint16)(unsafe.Pointer(pids)), int(capacity))
	blpSlice := unsafe.Slice((*uint16)(unsafe.Pointer(blps)), int(capacity))
	for i, entry := range entries {
		pidSlice[i] = entry.PID
		blpSlice[i] = entry.BLP
	}
	return C.int(len(entries))
}

// Encodes the sharer's RTT probe, carrying a monotonic clock reading in
// nanoseconds.
//
//export tailscreen_encode_ping
func tailscreen_encode_ping(serverUptimeNs C.uint64_t) C.tailscreen_buf {
	return cBuf(tailscreen.EncodePing(uint64(serverUptimeNs)))
}

// Parses an RTT probe. Returns 0 on a malformed datagram, 1 on success.
//
//export tailscreen_decode_ping
func tailscreen_decode_ping(data *C.uint8_t, length C.int, out *C.uint64_t) C.int {
	value, ok := tailscreen.DecodePing(goBytes(data, length))
	if !ok {
		return 0
	}
	if out != nil {
		*out = C.uint64_t(value)
	}
	return 1
}

// Encodes a receiver report. Pass include_recovery=0 for the 20-byte legacy
// layout, which is what a link that did not negotiate FEC must carry
// (TS-RRP-011).
//
//export tailscreen_encode_receiver_report
func tailscreen_encode_receiver_report(
	fracLostQ8 C.uint8_t, extHighestSeq C.uint32_t, jitterTicks C.uint32_t,
	lastPingTs C.uint64_t, delaySincePingMs C.uint16_t,
	fecRecovered C.uint16_t, nackRecovered C.uint16_t, includeRecovery C.int,
) C.tailscreen_buf {
	report := tailscreen.Report{
		FracLostQ8:       uint8(fracLostQ8),
		ExtHighestSeq:    uint32(extHighestSeq),
		JitterTicks:      uint32(jitterTicks),
		LastPingTs:       uint64(lastPingTs),
		DelaySincePingMs: uint16(delaySincePingMs),
		FECRecovered:     uint16(fecRecovered),
		NACKRecovered:    uint16(nackRecovered),
	}
	return cBuf(tailscreen.EncodeReport(report, includeRecovery != 0))
}

// Parses any of the three permitted report lengths, reading absent trailing
// counters as zero (TS-RRP-009). Returns 0 on a malformed datagram, 1 on
// success. Any out-parameter may be NULL.
//
//export tailscreen_decode_receiver_report
func tailscreen_decode_receiver_report(
	data *C.uint8_t, length C.int,
	fracLostQ8 *C.uint8_t, extHighestSeq *C.uint32_t, jitterTicks *C.uint32_t,
	lastPingTs *C.uint64_t, delaySincePingMs *C.uint16_t,
	fecRecovered *C.uint16_t, nackRecovered *C.uint16_t,
) C.int {
	report, ok := tailscreen.DecodeReport(goBytes(data, length))
	if !ok {
		return 0
	}
	if fracLostQ8 != nil {
		*fracLostQ8 = C.uint8_t(report.FracLostQ8)
	}
	if extHighestSeq != nil {
		*extHighestSeq = C.uint32_t(report.ExtHighestSeq)
	}
	if jitterTicks != nil {
		*jitterTicks = C.uint32_t(report.JitterTicks)
	}
	if lastPingTs != nil {
		*lastPingTs = C.uint64_t(report.LastPingTs)
	}
	if delaySincePingMs != nil {
		*delaySincePingMs = C.uint16_t(report.DelaySincePingMs)
	}
	if fecRecovered != nil {
		*fecRecovered = C.uint16_t(report.FECRecovered)
	}
	if nackRecovered != nil {
		*nackRecovered = C.uint16_t(report.NACKRecovered)
	}
	return 1
}

// ---------------------------------------------------------------------------
// RTP
// ---------------------------------------------------------------------------

// Encodes the 12-byte fixed header, always with V=2, P=0, X=0, CC=0
// (TS-VID-001).
//
//export tailscreen_encode_rtp_header
func tailscreen_encode_rtp_header(
	marker C.int, payloadType C.uint8_t, sequence C.uint16_t,
	timestamp C.uint32_t, ssrc C.uint32_t,
) C.tailscreen_buf {
	return cBuf(tailscreen.EncodeRTPHeader(tailscreen.RTPHeader{
		Marker:      marker != 0,
		PayloadType: uint8(payloadType),
		Sequence:    uint16(sequence),
		Timestamp:   uint32(timestamp),
		SSRC:        uint32(ssrc),
	}))
}

// Parses the fixed header and reports where the payload begins, having
// skipped any CSRC list and header extension (TS-VID-003). Returns 0 on a
// packet that is malformed or too short for the offset it declares.
//
//export tailscreen_decode_rtp_header
func tailscreen_decode_rtp_header(
	data *C.uint8_t, length C.int,
	marker *C.int, payloadType *C.uint8_t, sequence *C.uint16_t,
	timestamp *C.uint32_t, ssrc *C.uint32_t, payloadOffset *C.int,
) C.int {
	header, offset, ok := tailscreen.DecodeRTPHeader(goBytes(data, length))
	if !ok {
		return 0
	}
	if marker != nil {
		if header.Marker {
			*marker = 1
		} else {
			*marker = 0
		}
	}
	if payloadType != nil {
		*payloadType = C.uint8_t(header.PayloadType)
	}
	if sequence != nil {
		*sequence = C.uint16_t(header.Sequence)
	}
	if timestamp != nil {
		*timestamp = C.uint32_t(header.Timestamp)
	}
	if ssrc != nil {
		*ssrc = C.uint32_t(header.SSRC)
	}
	if payloadOffset != nil {
		*payloadOffset = C.int(offset)
	}
	return 1
}

// ---------------------------------------------------------------------------
// FEC
// ---------------------------------------------------------------------------

// Frames one parity datagram over a group of `count` consecutive packets
// beginning at `base_seq`.
//
//export tailscreen_encode_fec
func tailscreen_encode_fec(baseSeq C.uint16_t, count C.int, body *C.uint8_t, bodyLen C.int) C.tailscreen_buf {
	return cBuf(tailscreen.EncodeFEC(uint16(baseSeq), int(count), goBytes(body, bodyLen)))
}

// Parses a parity datagram, returning its body as a fresh buffer and writing
// the group's base sequence and size through the out-parameters. Every field
// is bounds-checked; a rejected datagram yields a NULL buffer
// (TS-FEC-001 … TS-FEC-003).
//
//export tailscreen_decode_fec
func tailscreen_decode_fec(data *C.uint8_t, length C.int, baseSeqOut *C.uint16_t, countOut *C.int) C.tailscreen_buf {
	baseSeq, count, body, ok := tailscreen.DecodeFEC(goBytes(data, length))
	if !ok {
		return rejected()
	}
	if baseSeqOut != nil {
		*baseSeqOut = C.uint16_t(baseSeq)
	}
	if countOut != nil {
		*countOut = C.int(count)
	}
	return cBuf(body)
}

// Computes the XOR parity over a group of RTP packets, given as `count`
// pointers and `count` lengths. Returns a NULL buffer for a degenerate group
// — fewer than two members, or a member too short to be an RTP packet.
//
//export tailscreen_parity_body
func tailscreen_parity_body(packets **C.uint8_t, lengths *C.int, count C.int) C.tailscreen_buf {
	group := gatherPackets(packets, lengths, count)
	if group == nil {
		return rejected()
	}
	body := tailscreen.ParityBody(group)
	if body == nil {
		return rejected()
	}
	return cBuf(body)
}

// Reconstructs the one missing packet of a group from the surviving members
// and the parity body. `missing_seq` comes from the caller's own gap
// tracking and `ssrc` from any member's header — neither rides in the parity.
//
// Returns a NULL buffer on any inconsistency, which includes a member whose
// payload exceeds the parity's padded region and a solved length that is
// impossible (TS-FEC-010). It never returns a truncated packet.
//
//export tailscreen_recover
func tailscreen_recover(
	missingSeq C.uint16_t, ssrc C.uint32_t,
	members **C.uint8_t, lengths *C.int, count C.int,
	body *C.uint8_t, bodyLen C.int,
) C.tailscreen_buf {
	group := gatherPackets(members, lengths, count)
	if group == nil && count > 0 {
		return rejected()
	}
	packet := tailscreen.Recover(uint16(missingSeq), uint32(ssrc), group, goBytes(body, bodyLen))
	if packet == nil {
		return rejected()
	}
	return cBuf(packet)
}

func gatherPackets(packets **C.uint8_t, lengths *C.int, count C.int) [][]byte {
	if count <= 0 || packets == nil || lengths == nil {
		return nil
	}
	ptrs := unsafe.Slice(packets, int(count))
	lens := unsafe.Slice(lengths, int(count))
	out := make([][]byte, 0, int(count))
	for i := 0; i < int(count); i++ {
		out = append(out, goBytes(ptrs[i], lens[i]))
	}
	return out
}

// ---------------------------------------------------------------------------
// TCP framing
// ---------------------------------------------------------------------------

// Encodes [type:1][length:4 BE][payload].
//
//export tailscreen_encode_frame
func tailscreen_encode_frame(msgType C.uint8_t, payload *C.uint8_t, payloadLen C.int) C.tailscreen_buf {
	return cBuf(tailscreen.EncodeFrame(tailscreen.MessageType(msgType), goBytes(payload, payloadLen)))
}

// The framed TCP channel is the one thing here that cannot be a pure
// function: a frame arrives across an arbitrary number of segments, so the
// parser has to remember what it has seen. Handles rather than pointers,
// because a Go pointer may not be held by C.
//
// Each handle carries its own lock: parsersMu guards only the table, and
// without a per-handle mutex a C caller feeding tailscreen_parser_append
// from a socket-reader thread while another thread drains
// tailscreen_parser_next would race on the parser's buffer — in a library
// whose header promises thread safety.
type frameParserHandle struct {
	mu     sync.Mutex
	parser tailscreen.FrameParser
}

var (
	parsersMu sync.Mutex
	parsers   = map[int64]*frameParserHandle{}
	nextID    int64
)

// Creates a framed-channel parser, returning its handle. Free it with
// tailscreen_parser_free; a leaked handle keeps its buffered bytes alive for
// the lifetime of the process.
//
//export tailscreen_parser_new
func tailscreen_parser_new() C.int64_t {
	parsersMu.Lock()
	defer parsersMu.Unlock()
	nextID++
	parsers[nextID] = &frameParserHandle{}
	return C.int64_t(nextID)
}

// Destroys a parser. Freeing an unknown handle is a no-op.
//
//export tailscreen_parser_free
func tailscreen_parser_free(handle C.int64_t) {
	parsersMu.Lock()
	defer parsersMu.Unlock()
	delete(parsers, int64(handle))
}

func lookupParser(handle C.int64_t) *frameParserHandle {
	parsersMu.Lock()
	defer parsersMu.Unlock()
	return parsers[int64(handle)]
}

// Feeds received bytes to a parser. Returns 0 for an unknown handle, 1
// otherwise. A poisoned parser buffers nothing further (TS-TCP-005).
//
//export tailscreen_parser_append
func tailscreen_parser_append(handle C.int64_t, data *C.uint8_t, length C.int) C.int {
	h := lookupParser(handle)
	if h == nil {
		return 0
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	// No intermediate copy: FrameParser.Append copies the bytes into its own
	// buffer and never retains the caller's view, and the C buffer is valid
	// for the duration of the call — which the lock bounds.
	h.parser.Append(goBytes(data, length))
	return 1
}

// Yields the next complete frame with an assigned message type, skipping
// frames whose type byte is unassigned (TS-TCP-003). Returns 0 when more
// bytes are needed, the parser is poisoned, or the handle is unknown; 1 on a
// frame, whose payload the caller frees with tailscreen_free.
//
//export tailscreen_parser_next
func tailscreen_parser_next(handle C.int64_t, out *C.tailscreen_frame) C.int {
	h := lookupParser(handle)
	if h == nil || out == nil {
		return 0
	}
	h.mu.Lock()
	frame, ok := h.parser.Next()
	h.mu.Unlock()
	if !ok {
		return 0
	}
	buf := cBuf(frame.Payload)
	out._type = C.uint8_t(frame.Type)
	out.payload = buf.data
	out.len = buf.len
	return 1
}

// Reports whether a frame declared a payload longer than 1 MiB, which
// poisons the stream permanently: the caller must close the connection
// (TS-TCP-004, TS-TCP-005). Returns 1 for an unknown handle, since a parser
// that does not exist can parse nothing.
//
//export tailscreen_parser_corrupt
func tailscreen_parser_corrupt(handle C.int64_t) C.int {
	h := lookupParser(handle)
	if h == nil {
		return 1
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.parser.Corrupt() {
		return 1
	}
	return 0
}
