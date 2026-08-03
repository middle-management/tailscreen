#ifndef TS_PIPEWIRE_FAKE_SOURCE_H
#define TS_PIPEWIRE_FAKE_SOURCE_H

#include <stdint.h>

// A synthetic PipeWire video producer, for tests. The PipeWire counterpart of
// CPortalFakeBus, and NOT part of the library product for the same reason.
//
// WHY THIS EXISTS. The portal half of this package could always be exercised
// against a fake bus; the PipeWire half could not be exercised at all, because
// the only producer we had was a compositor, and a compositor needs a desktop
// session and a person to click a consent dialog. So `portal_stream.c` shipped
// compiled, linked, and never once run: no format negotiated, no buffer
// dequeued, no pixel delivered. Every one of its four documented traps was
// reasoned from the API contract rather than observed.
//
// A local `pipewire` daemon plus this producer closes that gap without a
// compositor anywhere: it is a real daemon, a real format negotiation, real
// shared-memory buffers and a real `process` callback on PipeWire's own thread.
//
// WHAT IT STILL DOES NOT COVER, stated here so nobody reads more into a green
// run than is in it:
//
//   * No consent dialog and no real portal. The (fd, node id) that a real share
//     obtains from OpenPipeWireRemote is obtained here by connecting a socket to
//     the daemon directly — the same kind of fd, from a different place.
//   * No session manager. On a desktop, wireplumber links the capture stream to
//     the compositor's node in response to PW_STREAM_FLAG_AUTOCONNECT; there is
//     no session manager in a CI container, so `ts_pwfake_link_to` creates the
//     link explicitly. The autoconnect handshake itself therefore stays
//     unproven.
//   * No DMA-BUF. Producing one needs a GPU, so the buffer-type constraint that
//     keeps us off that path is still argued rather than demonstrated.
//
// What it DOES cover is everything between those: that a format is agreed at
// all, that the negotiated format is the one we asked for and not a plausible
// neighbour, that buffers arrive with a mappable pointer, that `chunk->stride`
// is honoured rather than assumed to be `width * 4`, and that the bytes the
// callback hands upward are in the channel order `BGRAToI420` expects.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int width;
    int height;
    // Bytes of row padding BEYOND width*4. Deliberately non-zero in the tests:
    // a producer that pads is the normal case on real compositors, and a
    // consumer that reads at width*4 smears the image diagonally instead of
    // failing. Padding is filled with ts_pwfake_padding_byte() so a consumer
    // that ignores stride reads recognisable garbage rather than plausible
    // pixels.
    int stride_padding;
    int fps;
    // Offer ONLY SPA_VIDEO_FORMAT_RGBx. Nothing in this package should ever
    // negotiate that: RGBx has red and blue where BGRAToI420 expects blue and
    // red, so accepting it produces a picture with swapped channels and no
    // error anywhere. A consumer facing this producer must end up with no
    // stream at all.
    int offer_rgbx_only;
    // Claim a row pitch far wider than the buffer actually holds. A producer
    // this broken is a compositor bug, but believing it is a read past the end
    // of a shared mapping — so the consumer must DROP the frame, and this is
    // the only way to watch it do so.
    int corrupt_stride;
    // Set SPA_CHUNK_FLAG_CORRUPTED: the producer saying "I could not finish
    // writing this". Encoding it anyway puts a torn frame on every viewer's
    // screen and holds it there until the next keyframe.
    int mark_corrupted;
} ts_pwfake_config_t;

typedef struct ts_pwfake ts_pwfake_t;

// Start the producer and connect it to the daemon named by PIPEWIRE_RUNTIME_DIR
// or XDG_RUNTIME_DIR. Returns NULL if no daemon is reachable.
ts_pwfake_t *ts_pwfake_start(const ts_pwfake_config_t *config);
void ts_pwfake_stop(ts_pwfake_t *fake);

// The producer's node id, or 0 before the daemon has assigned one. This is what
// a real portal would have returned from Start().
uint32_t ts_pwfake_node_id(ts_pwfake_t *fake);

// Link this producer to a consumer node, standing in for the session manager
// that would do it on a desktop in response to PW_STREAM_FLAG_AUTOCONNECT.
// Returns 0 on success.
int ts_pwfake_link_to(ts_pwfake_t *fake, uint32_t consumer_node_id);

// Frames the producer has actually filled and queued. A consumer seeing zero
// frames while this is also zero is a broken harness, not a broken consumer.
uint64_t ts_pwfake_frames_produced(ts_pwfake_t *fake);

const char *ts_pwfake_last_error(ts_pwfake_t *fake);

// A socket connected to the running daemon — the same kind of descriptor
// OpenPipeWireRemote hands back, so the consumer under test takes the identical
// path it takes in production. Negative on failure. The caller owns it, and
// ts_pwcap_open takes that ownership.
int ts_pwfake_open_daemon_fd(void);

// The test pattern, exported so the producer and the checker cannot disagree
// about it — a pattern defined twice is a gate that passes when both copies are
// wrong the same way.
//
// Each channel is a DIFFERENT function of (x, y), which is what makes the
// checks sharp: a channel swap (trap 2) and a row-addressing error (trap 4)
// both land on values this function never produces at that coordinate.
void ts_pwfake_expected_pixel(int x, int y, uint8_t out_bgra[4]);

// The byte every padding region is filled with.
uint8_t ts_pwfake_padding_byte(void);

#ifdef __cplusplus
}
#endif

#endif
