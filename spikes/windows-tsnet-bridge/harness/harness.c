// Leg B of the Windows bridge spike — the C side.
//
// The question this answers: when Go hands a socket across the c-archive
// boundary as a plain `int`, can ordinary C recv() read from it? That is the
// exact contract libtailscale's C API makes today (tailscale_conn is an int the
// caller read()s and write()s), and the one the Swift wrapper is built on. If
// this works, the Windows bridge can keep the existing API shape and the Swift
// side needs only recv/send in place of read/write.
//
// Build: compile against the c-archive produced by
//   go build -buildmode=c-archive -o spike.a .
// then link with ws2_32.

#include <stdio.h>
#include <string.h>
#include <winsock2.h>

#include "spike.h"

static int failures = 0;

static void fail(const char *what, const char *detail) {
    fprintf(stderr, "FAIL: %s: %s\n", what, detail);
    failures++;
}

static void pass(const char *what) { printf("ok: %s\n", what); }

// recv() the exact number of bytes expected, looping over short reads the way
// any real stream consumer must.
static int recv_exactly(SOCKET s, char *buf, int want) {
    int got = 0;
    while (got < want) {
        int n = recv(s, buf + got, want - got, 0);
        if (n == 0) return -1;         // peer closed
        if (n == SOCKET_ERROR) return -2;
        got += n;
    }
    return got;
}

static void test_stream_pair(void) {
    int fd = SpikeStreamPair();
    if (fd < 0) {
        fail("stream pair", "Go side could not create the pair");
        return;
    }

    int want = SpikeStreamPayloadLen();
    char buf[512];
    if (want <= 0 || want > (int)sizeof(buf)) {
        fail("stream pair", "unexpected payload length");
        return;
    }

    int got = recv_exactly((SOCKET)fd, buf, want);
    if (got != want) {
        char detail[128];
        snprintf(detail, sizeof(detail), "recv_exactly returned %d, want %d", got, want);
        fail("stream pair", detail);
        return;
    }

    if (!SpikeStreamPayloadMatches(buf, want)) {
        fail("stream pair", "payload mismatch");
        return;
    }
    pass("C recv() reads bytes written by Go over a handed-over SOCKET");
}

// The one that matters for the video path: patch 013 carries UDP over a
// SOCK_DGRAM socketpair, and Windows AF_UNIX has no datagram mode at all. If
// boundaries are not preserved, RTP tears under load in a way no smoke test
// would catch.
static void test_packet_pair(void) {
    int fd = SpikePacketPair();
    if (fd < 0) {
        fail("packet pair", "Go side could not create the pair");
        return;
    }

    int count = SpikePacketCount();
    for (int i = 0; i < count; i++) {
        int want = SpikePacketSizeAt(i);
        // Deliberately oversized: if boundaries were lost, one recv would
        // return several datagrams concatenated and the length check fails.
        char buf[4096];
        int n = recv((SOCKET)fd, buf, (int)sizeof(buf), 0);
        if (n == SOCKET_ERROR) {
            char detail[128];
            snprintf(detail, sizeof(detail), "datagram %d: recv failed (WSA %d)", i, WSAGetLastError());
            fail("packet pair", detail);
            return;
        }
        if (n != want) {
            char detail[160];
            snprintf(detail, sizeof(detail),
                     "datagram %d: got %d bytes, want exactly %d -- message boundary not preserved",
                     i, n, want);
            fail("packet pair", detail);
            return;
        }
        // Each datagram is filled with its 1-based index.
        for (int b = 0; b < n; b++) {
            if ((unsigned char)buf[b] != (unsigned char)(i + 1)) {
                fail("packet pair", "datagram contents mismatched (reordered or merged)");
                return;
            }
        }
    }
    pass("C recv() preserves datagram boundaries over the handed-over SOCKET");
}

int main(void) {
    // Go's net package has already initialised Winsock in this process, but a C
    // consumer of the archive cannot assume that, so do it explicitly.
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        fprintf(stderr, "FAIL: WSAStartup\n");
        return 1;
    }

    test_stream_pair();
    test_packet_pair();

    WSACleanup();

    if (failures) {
        fprintf(stderr, "\n%d check(s) failed\n", failures);
        return 1;
    }
    printf("\nall checks passed\n");
    return 0;
}
