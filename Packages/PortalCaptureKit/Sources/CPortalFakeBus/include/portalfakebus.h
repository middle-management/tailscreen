#ifndef TS_PORTALFAKEBUS_H
#define TS_PORTALFAKEBUS_H

#include <stdint.h>

// A fake `org.freedesktop.portal.ScreenCast`, for testing the handshake in
// CPortalCapture without a desktop session.
//
// WHAT THIS EXISTS FOR, precisely, because a fake that is mistaken for a real
// gate is worse than no gate:
//
//   It proves the CLIENT half of the D-Bus protocol — that the options dicts
//   are well-formed enough for a server to read, that the Request path is
//   derived and subscribed to before the call so a fast Response is not
//   missed, that the Response's `streams` array parses, that a `restore_token`
//   is picked up, that a cancel is reported as a cancel, and that a file
//   descriptor survives the OpenPipeWireRemote round trip.
//
//   It proves NOTHING about a real portal: not the consent dialog, not what
//   any actual compositor returns, not PipeWire, not a single pixel. It cannot
//   — the real portal is defined by a human clicking a button.
//
// Kept out of the shipped library on purpose. A screen-capture library that
// carried a way to impersonate the consent authority is not something to have
// lying on disk, however inert.

typedef struct ts_fakeportal ts_fakeportal_t;

// What the fake should answer Start with.
#define TS_FAKEPORTAL_ANSWER_OK 0
#define TS_FAKEPORTAL_ANSWER_CANCEL 1
#define TS_FAKEPORTAL_ANSWER_ERROR 2

typedef struct {
    uint32_t node_id;
    int32_t width;
    int32_t height;
    uint32_t source_type;
    // One of TS_FAKEPORTAL_ANSWER_*.
    int start_answer;
    // Non-zero to include a `restore_token` in the Start results.
    int offer_restore_token;
} ts_fakeportal_config_t;

// Claim org.freedesktop.portal.Desktop on the session bus this process can
// see, and serve from a thread of its own. Returns NULL if there is no bus or
// the name is already owned — which, on a machine with a real desktop, it will
// be. That is the correct failure: the fake must never displace the real one.
ts_fakeportal_t *ts_fakeportal_start(const ts_fakeportal_config_t *config);

void ts_fakeportal_stop(ts_fakeportal_t *f);

const char *ts_fakeportal_last_error(const ts_fakeportal_t *f);

// How many ScreenCast method calls the fake has served. Lets a test assert the
// client actually made all three calls rather than short-circuiting.
int ts_fakeportal_call_count(const ts_fakeportal_t *f);

#endif
