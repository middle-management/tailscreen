#ifndef TS_PORTALCAPTURE_H
#define TS_PORTALCAPTURE_H

#include <stddef.h>
#include <stdint.h>

// C shim for xdg-desktop-portal ScreenCast + PipeWire capture, keeping Swift
// out of libdbus's iterator API and SPA's POD macros — the same division of
// labour CX11Capture uses for XCB.
//
// Two halves that never call each other:
//
//   ts_portal_*  the D-Bus handshake. Ends with a PipeWire file descriptor and
//                a node id, and knows nothing about pixels.
//   ts_pwcap_*   the PipeWire stream. Starts from that fd and node id, and
//                knows nothing about D-Bus.
//
// The split is deliberate: the handshake can be exercised against a fake
// portal on a private bus with no PipeWire daemon in the picture, which is the
// only part of this file a machine without a desktop session can test at all.
//
// NOTE ON PIXELS. This shim performs NO colour conversion. It hands back
// packed BGRA (or BGRx) and a stride; the repo's portable `BGRAToI420`
// (TailscreenProtocol) converts. Same split as WGCCaptureKit → the Windows
// sharer. There is exactly one BGRA→I420 implementation in Swift and one in
// C (CX11Capture), and adding a third here would be a third thing to keep in
// step with the viewer's YUV shader.

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Result codes
//
// Split finer than "it failed" because the sharer UI has to say different
// things: a cancelled consent dialog is a normal outcome and must never read
// as an error, while "no portal on this bus" means the user needs to install
// something.
// ---------------------------------------------------------------------------
#define TS_PORTAL_OK 0
#define TS_PORTAL_ERR_NO_BUS (-1)      // no session bus (headless, or no DBUS_SESSION_BUS_ADDRESS)
#define TS_PORTAL_ERR_NO_PORTAL (-2)   // bus is there, org.freedesktop.portal.Desktop is not
#define TS_PORTAL_ERR_CANCELLED (-3)   // the user dismissed the consent dialog. Not an error.
#define TS_PORTAL_ERR_PORTAL (-4)      // the portal answered with a failure
#define TS_PORTAL_ERR_TIMEOUT (-5)     // no Response signal inside the deadline
#define TS_PORTAL_ERR_PROTOCOL (-6)    // a reply we could not parse
#define TS_PORTAL_ERR_NO_STREAMS (-7)  // consent given, but nothing to capture
#define TS_PORTAL_ERR_ARGS (-8)

// Portal source-type bits (org.freedesktop.portal.ScreenCast AvailableSourceTypes).
#define TS_PORTAL_SOURCE_MONITOR 1u
#define TS_PORTAL_SOURCE_WINDOW 2u
#define TS_PORTAL_SOURCE_VIRTUAL 4u

// Portal cursor-mode bits (AvailableCursorModes).
#define TS_PORTAL_CURSOR_HIDDEN 1u
#define TS_PORTAL_CURSOR_EMBEDDED 2u
#define TS_PORTAL_CURSOR_METADATA 4u

// Portal persist modes for SelectSources.
#define TS_PORTAL_PERSIST_NONE 0u
#define TS_PORTAL_PERSIST_WHILE_RUNNING 1u
#define TS_PORTAL_PERSIST_UNTIL_REVOKED 2u

typedef struct ts_portal ts_portal_t;

typedef struct {
    // Bitwise-OR of TS_PORTAL_SOURCE_*. Asking for MONITOR|WINDOW is what
    // makes "share one window" possible at all on this platform — the picker
    // the user gets is the portal's, not ours.
    uint32_t source_types;
    // One of TS_PORTAL_CURSOR_*. EMBEDDED composites the pointer into the
    // frames, which is what a screen share wants; METADATA delivers it
    // out-of-band and would need a compositing step we do not have.
    uint32_t cursor_mode;
    // Let the user pick more than one source. The capture side handles one
    // stream today, so callers pass 0.
    int multiple;
    // Ask the portal to remember this grant, and hand back a restore token.
    // One of TS_PORTAL_PERSIST_*. This is the PORTAL's own consent memory,
    // recorded because the user ticked its box — it is not a way to skip the
    // dialog, and there is no such way.
    uint32_t persist_mode;
    // A token from a previous session's ts_portal_restore_token(), or NULL.
    // The portal decides whether to honour it; it may still prompt.
    const char *restore_token;
    // Whole-negotiation budget INCLUDING the time the dialog sits on screen
    // waiting for a human. Anything under ~30s will time out on a real
    // desktop more often than it succeeds.
    int timeout_ms;
} ts_portal_request_t;

typedef struct {
    uint32_t node_id;
    // Portal-reported size, or -1 when it did not report one (it is an
    // optional property). The negotiated PipeWire format is the authority
    // either way; this is only useful for logging before the stream opens.
    int32_t width;
    int32_t height;
    // TS_PORTAL_SOURCE_* for this stream, or 0 when unreported.
    uint32_t source_type;
} ts_portal_stream_t;

// A portal session. Owns a PRIVATE bus connection, so it cannot be disturbed
// by, or disturb, any other libdbus user in the process.
ts_portal_t *ts_portal_new(void);
void ts_portal_free(ts_portal_t *p);

// Connect to the session bus and check the portal is there.
// Returns TS_PORTAL_OK, TS_PORTAL_ERR_NO_BUS or TS_PORTAL_ERR_NO_PORTAL.
// Separated from ts_portal_negotiate so a host can answer "can this machine
// share at all?" without raising a dialog on somebody's screen.
int ts_portal_connect(ts_portal_t *p);

// What the portal says it can offer, read from its AvailableSourceTypes /
// AvailableCursorModes properties. Zero means "could not read it" — the
// properties are versioned, and an old portal simply does not have them.
// Requires ts_portal_connect first.
uint32_t ts_portal_available_source_types(ts_portal_t *p);
uint32_t ts_portal_available_cursor_modes(ts_portal_t *p);

// CreateSession -> SelectSources -> Start. RAISES THE CONSENT DIALOG and
// blocks until the user answers or `timeout_ms` elapses.
//
// Fills up to `max_streams` entries and writes the count to `out_count`.
// Returns TS_PORTAL_OK or one of the TS_PORTAL_ERR_* codes above; a user who
// clicks Cancel produces TS_PORTAL_ERR_CANCELLED, which callers must render
// as "no thanks", not as a failure.
int ts_portal_negotiate(ts_portal_t *p, const ts_portal_request_t *req,
                        ts_portal_stream_t *out_streams, int max_streams,
                        int *out_count);

// The restore token from the last successful negotiate, or NULL. Only
// produced when `persist_mode` asked for one and the portal agreed.
const char *ts_portal_restore_token(const ts_portal_t *p);

// Human-readable detail about the last failure. Never NULL.
const char *ts_portal_last_error(const ts_portal_t *p);

// OpenPipeWireRemote on the live session. Returns a file descriptor the
// caller owns, or a negative TS_PORTAL_ERR_*.
//
// Hand it to ts_pwcap_open, which TAKES OWNERSHIP (pw_context_connect_fd
// closes it). Close it yourself only if you never get that far.
int ts_portal_open_pipewire_fd(ts_portal_t *p);

// Close the portal session. The compositor stops capturing and, on most
// desktops, drops its "screen is being shared" indicator. Idempotent.
void ts_portal_close_session(ts_portal_t *p);

// Derive the org.freedesktop.portal.Request object path a Response will
// arrive on, from the caller's unique bus name and a handle token.
//
// Exposed because it is the one piece of the handshake that is pure string
// arithmetic and the one whose failure mode is silent: get it wrong and the
// client subscribes to a path nothing is ever emitted on, so every call times
// out with no error anywhere. Tests pin it against hand-written expectations.
//
// Returns 0 on success, TS_PORTAL_ERR_ARGS on bad input or truncation.
int ts_portal_request_path(const char *unique_name, const char *token,
                           char *out, size_t out_len);

// ---------------------------------------------------------------------------
// PipeWire stream
// ---------------------------------------------------------------------------

typedef struct ts_pwcap ts_pwcap_t;

// One captured frame, packed BGRA/BGRx. `stride` is the row pitch in BYTES
// and is NOT width*4 in general — PipeWire producers pad rows.
// Called on the stream's own thread.
typedef void (*ts_pwcap_frame_cb)(void *user, const uint8_t *bgra, int stride,
                                  int width, int height);

#define TS_PWCAP_STATE_CONNECTING 0
#define TS_PWCAP_STATE_STREAMING 1
#define TS_PWCAP_STATE_ERROR 2
// The producer went away: the user hit the compositor's "stop sharing", or
// the shared window closed. Distinct from ERROR because the sharer must tear
// down quietly rather than trying to restart something that is gone.
#define TS_PWCAP_STATE_ENDED 3

typedef void (*ts_pwcap_state_cb)(void *user, int state, const char *detail);

// Open a capture stream on `node_id` over `pipewire_fd`.
//
// TAKES OWNERSHIP of `pipewire_fd` unconditionally — including on failure,
// where it is closed before returning NULL.
ts_pwcap_t *ts_pwcap_open(int pipewire_fd, uint32_t node_id,
                          ts_pwcap_frame_cb on_frame, ts_pwcap_state_cb on_state,
                          void *user);

void ts_pwcap_close(ts_pwcap_t *c);

// Negotiated frame size, once a format has been agreed. Returns 0 and writes
// nothing before that. Sizes can change mid-stream (a resized window), which
// is why this is a query rather than a value fixed at open.
int ts_pwcap_size(ts_pwcap_t *c, int *width, int *height);

// Frames delivered to the callback so far. The liveness signal a
// `CaptureEncoding` backend feeds to the server's hung-backend watchdog.
uint64_t ts_pwcap_frame_count(ts_pwcap_t *c);

// libpipewire's compiled-in version string. The link check: a library target
// is compiled but never linked, so without an executable calling into
// libpipewire a missing -lpipewire-0.3 stays invisible until something
// downstream links it.
const char *ts_pwcap_library_version(void);

#ifdef __cplusplus
}
#endif

#endif
