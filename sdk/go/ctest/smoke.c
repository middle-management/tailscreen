// Smoke test for libtailscreen.a — the C side of the archive, exercised as a
// C caller sees it.
//
// It is deliberately not a second conformance suite: the vectors already run
// against the Go package this archive wraps, and re-encoding all 162 of them
// in C would test the same codecs twice while testing the ABI once. What is
// only reachable from here is the ABI itself — that the header's signatures
// match, that the archive links, that a returned buffer is real malloc'd
// memory the caller can free, that an out-parameter is written, and that a
// rejection arrives as a NULL pointer rather than as a crash.
//
// Build and run it from the repository root:
//
//     make libtailscreen-check
//
// It lives here rather than beside capi.go for a mechanical reason: cgo
// compiles every .c file in a package's own directory, so a C file next to
// capi.go would be built INTO the archive rather than against it.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libtailscreen.h"  // generated into sdk/go/build by `make libtailscreen`

static int failures = 0;

static void check(int condition, const char *what) {
    if (condition) {
        printf("  ok    %s\n", what);
    } else {
        printf("  FAIL  %s\n", what);
        failures++;
    }
}

static int bytes_are(tailscreen_buf buf, const uint8_t *want, int want_len, const char *what) {
    int ok = buf.data != NULL && buf.len == want_len && memcmp(buf.data, want, (size_t)want_len) == 0;
    if (!ok && buf.data != NULL) {
        printf("        got %d bytes:", buf.len);
        for (int i = 0; i < buf.len && i < 32; i++) printf(" %02x", buf.data[i]);
        printf("\n");
    }
    check(ok, what);
    return ok;
}

int main(void) {
    printf("libtailscreen smoke test\n");

    check(tailscreen_spec_version() == 1, "spec version is 1");
    check(tailscreen_default_port() == 7447, "default port is 7447");

    // --- the first-byte demultiplex -------------------------------------
    {
        uint8_t rtp[1] = {0x80};
        uint8_t control[1] = {0x03};
        check(tailscreen_classify(rtp, 1) == 1, "0x80 classifies as RTP");
        check(tailscreen_classify(control, 1) == 2, "0x03 classifies as control");
        check(tailscreen_classify(NULL, 0) == 0, "an empty datagram classifies as empty");
        check(tailscreen_decode_control(control, 1) == 0x03, "PLI decodes to 0x03");

        uint8_t unassigned[1] = {0x7F};
        check(tailscreen_decode_control(unassigned, 1) == -1, "an unassigned byte is rejected");
    }

    // --- the handshake ---------------------------------------------------
    {
        tailscreen_buf hello = tailscreen_encode_hello(0x07);
        const uint8_t want_hello[] = {0x00, 0x07};
        bytes_are(hello, want_hello, 2, "extended HELLO carries the capability byte");
        check(tailscreen_decode_hello_caps(hello.data, hello.len) == 0x07, "capabilities round-trip");
        tailscreen_free(hello.data);

        // The plain five-byte form, which is what a viewer that advertised
        // nothing must receive (TS-CAP-004).
        tailscreen_buf plain = tailscreen_encode_hello_ack(2, 0, 0);
        const uint8_t want_plain[] = {0x04, 0x00, 0x00, 0x00, 0x02};
        bytes_are(plain, want_plain, 5, "plain HELLO_ACK is five bytes");
        tailscreen_free(plain.data);

        tailscreen_buf extended = tailscreen_encode_hello_ack(7, 0x1F, 1);
        const uint8_t want_extended[] = {0x04, 0x00, 0x00, 0x00, 0x07, 0x1F};
        bytes_are(extended, want_extended, 6, "extended HELLO_ACK is six bytes");

        uint32_t ssrc = 0;
        uint8_t caps = 0;
        check(tailscreen_decode_hello_ack(extended.data, extended.len, &ssrc, &caps) == 1,
              "extended HELLO_ACK parses");
        check(ssrc == 7 && caps == 0x1F, "SSRC and capabilities arrive through the out-parameters");
        tailscreen_free(extended.data);
    }

    // --- NACK -------------------------------------------------------------
    {
        uint16_t pids[2] = {1000, 2000};
        uint16_t blps[2] = {5, 0};
        tailscreen_buf nack = tailscreen_encode_nack(pids, blps, 2);
        const uint8_t want[] = {0x0A, 0x02, 0x03, 0xE8, 0x00, 0x05, 0x07, 0xD0, 0x00, 0x00};
        bytes_are(nack, want, 10, "NACK encodes two entries");

        uint16_t got_pids[4] = {0}, got_blps[4] = {0};
        int n = tailscreen_decode_nack(nack.data, nack.len, got_pids, got_blps, 4);
        check(n == 2 && got_pids[0] == 1000 && got_blps[0] == 5 && got_pids[1] == 2000,
              "NACK entries round-trip");
        tailscreen_free(nack.data);

        // A truncated entry list yields nothing, not a prefix (TS-NCK-002).
        uint8_t truncated[] = {0x0A, 0x02, 0x03, 0xE8, 0x00, 0x05, 0x07};
        check(tailscreen_decode_nack(truncated, 7, got_pids, got_blps, 4) == 0,
              "a truncated NACK yields no entries");
    }

    // --- receiver report --------------------------------------------------
    {
        tailscreen_buf rr = tailscreen_encode_receiver_report(13, 70000, 900, 1234567890123456789ULL,
                                                              17, 5, 9, 1);
        check(rr.len == 24, "the extended receiver report is 24 bytes");

        uint8_t frac = 0;
        uint64_t ping = 0;
        uint16_t fec = 0, nack_recovered = 0;
        check(tailscreen_decode_receiver_report(rr.data, rr.len, &frac, NULL, NULL, &ping, NULL,
                                                &fec, &nack_recovered) == 1,
              "the receiver report parses");
        check(frac == 13 && ping == 1234567890123456789ULL && fec == 5 && nack_recovered == 9,
              "its fields round-trip, including the 64-bit ping echo");

        // The legacy 20-byte form must read its absent counters as zero.
        check(tailscreen_decode_receiver_report(rr.data, 20, NULL, NULL, NULL, NULL, NULL,
                                                &fec, &nack_recovered) == 1 &&
                  fec == 0 && nack_recovered == 0,
              "the 20-byte form reads absent counters as zero");
        tailscreen_free(rr.data);
    }

    // --- RTP --------------------------------------------------------------
    {
        tailscreen_buf header = tailscreen_encode_rtp_header(1, 97, 65535, 90000, 42);
        check(header.len == 12 && header.data[0] == 0x80 && header.data[1] == (0x80 | 97),
              "the RTP header is 12 bytes with V=2 and the marker set");

        int marker = 0, offset = 0;
        uint8_t pt = 0;
        uint16_t seq = 0;
        uint32_t ts = 0, ssrc = 0;
        check(tailscreen_decode_rtp_header(header.data, header.len, &marker, &pt, &seq, &ts, &ssrc,
                                           &offset) == 1,
              "the RTP header parses");
        check(marker == 1 && pt == 97 && seq == 65535 && ts == 90000 && ssrc == 42 && offset == 12,
              "its fields round-trip");
        tailscreen_free(header.data);

        uint8_t version_one[12] = {0x40, 0x60, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
        check(tailscreen_decode_rtp_header(version_one, 12, NULL, NULL, NULL, NULL, NULL, NULL) == 0,
              "a version-1 packet is rejected");
    }

    // --- FEC: build a group, lose one, get it back ------------------------
    {
        uint8_t packets[3][20];
        uint8_t *ptrs[3];
        int lengths[3];
        for (int i = 0; i < 3; i++) {
            tailscreen_buf header = tailscreen_encode_rtp_header(i == 2, 96, (uint16_t)(500 + i),
                                                                 90000, 42);
            memcpy(packets[i], header.data, 12);
            tailscreen_free(header.data);
            for (int j = 12; j < 20; j++) packets[i][j] = (uint8_t)(i * 31 + j);
            ptrs[i] = packets[i];
            lengths[i] = 20;
        }

        tailscreen_buf body = tailscreen_parity_body(ptrs, lengths, 3);
        check(body.data != NULL && body.len == 15, "parity covers the group");

        tailscreen_buf parity = tailscreen_encode_fec(500, 3, body.data, body.len);
        uint16_t base_seq = 0;
        int count = 0;
        tailscreen_buf decoded = tailscreen_decode_fec(parity.data, parity.len, &base_seq, &count);
        check(decoded.data != NULL && base_seq == 500 && count == 3, "the parity datagram parses");

        // The middle packet never arrived.
        uint8_t *survivors[2] = {packets[0], packets[2]};
        int survivor_lengths[2] = {20, 20};
        tailscreen_buf recovered = tailscreen_recover(501, 42, survivors, survivor_lengths, 2,
                                                      decoded.data, decoded.len);
        bytes_are(recovered, packets[1], 20, "the lost packet is recovered byte for byte");

        tailscreen_free(recovered.data);
        tailscreen_free(decoded.data);
        tailscreen_free(parity.data);
        tailscreen_free(body.data);

        // A parity body one byte short of describing any packet is rejected
        // rather than solved (TS-FEC-002).
        uint8_t stunted[] = {0x0D, 0x01, 0xF4, 0x03, 1, 2, 3, 4, 5, 6};
        tailscreen_buf bad = tailscreen_decode_fec(stunted, 10, NULL, NULL);
        check(bad.data == NULL, "a too-short parity body is rejected");
    }

    // --- the framed TCP channel -------------------------------------------
    {
        const char *json = "{\"type\":\"clearAll\"}";
        tailscreen_buf annotation = tailscreen_encode_frame(0x03, (uint8_t *)json, (int)strlen(json));
        tailscreen_buf unknown = tailscreen_encode_frame(0xFF, (uint8_t *)"newer", 5);
        tailscreen_buf control_request = tailscreen_encode_frame(0x06, NULL, 0);

        int64_t parser = tailscreen_parser_new();
        check(parser != 0, "a parser handle is allocated");

        // Feed the stream one byte at a time: a frame must survive arriving
        // across any number of segments (TS-TCP-006).
        tailscreen_buf chunks[3] = {annotation, unknown, control_request};
        int frames_seen = 0;
        uint8_t first_payload[64];
        int first_len = 0;
        for (int c = 0; c < 3; c++) {
            for (int i = 0; i < chunks[c].len; i++) {
                tailscreen_parser_append(parser, chunks[c].data + i, 1);
                tailscreen_frame frame;
                while (tailscreen_parser_next(parser, &frame) == 1) {
                    if (frames_seen == 0) {
                        first_len = frame.len;
                        memcpy(first_payload, frame.payload, (size_t)frame.len);
                    }
                    frames_seen++;
                    tailscreen_free(frame.payload);
                }
            }
        }
        check(frames_seen == 2, "the unassigned message type was skipped, the other two were not");
        check(first_len == (int)strlen(json) && memcmp(first_payload, json, (size_t)first_len) == 0,
              "the payload survived a byte-at-a-time delivery");
        check(tailscreen_parser_corrupt(parser) == 0, "the stream is not poisoned");
        tailscreen_parser_free(parser);

        // A frame declaring more than 1 MiB poisons the stream permanently
        // (TS-TCP-004, TS-TCP-005).
        int64_t poisoned = tailscreen_parser_new();
        uint8_t oversize[5] = {0x03, 0xFF, 0xFF, 0xFF, 0xFF};
        tailscreen_parser_append(poisoned, oversize, 5);
        tailscreen_frame frame;
        check(tailscreen_parser_next(poisoned, &frame) == 0, "the oversized frame yields nothing");
        check(tailscreen_parser_corrupt(poisoned) == 1, "the parser reports the stream poisoned");
        tailscreen_parser_append(poisoned, annotation.data, annotation.len);
        check(tailscreen_parser_next(poisoned, &frame) == 0, "nothing parses after poisoning");
        tailscreen_parser_free(poisoned);

        tailscreen_free(annotation.data);
        tailscreen_free(unknown.data);
        tailscreen_free(control_request.data);
    }

    if (failures == 0) {
        printf("all checks passed\n");
        return 0;
    }
    printf("%d check(s) failed\n", failures);
    return 1;
}
