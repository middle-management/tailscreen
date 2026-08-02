#include "include/portalcapture.h"

#include <dbus/dbus.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// The org.freedesktop.portal.ScreenCast handshake.
//
// Shape of the protocol, because it is unusual enough that code written to the
// obvious model does not work:
//
//   Every portal method returns IMMEDIATELY with an object path, and the real
//   answer arrives later as an org.freedesktop.portal.Request::Response signal
//   on that path. The client is expected to compute the path ITSELF from its
//   own unique bus name plus a token it chose, and to subscribe BEFORE making
//   the call — otherwise a portal that answers fast emits the signal before
//   the match rule exists and the client waits forever. That is the single
//   most likely way for this file to break, and it breaks silently: every call
//   times out, with no error from anything.
//
//   The returned path is still checked against the computed one, and the
//   returned one wins if they differ. The spec requires this and it is not
//   theoretical — the derivation depends on the caller's unique name, which
//   is not something we get to be confident about across portal versions.

#define PORTAL_BUS "org.freedesktop.portal.Desktop"
#define PORTAL_PATH "/org/freedesktop/portal/desktop"
#define SCREENCAST_IFACE "org.freedesktop.portal.ScreenCast"
#define REQUEST_IFACE "org.freedesktop.portal.Request"
#define SESSION_IFACE "org.freedesktop.portal.Session"
#define PROPERTIES_IFACE "org.freedesktop.DBus.Properties"

struct ts_portal {
    DBusConnection *conn;
    char *session_handle;
    char *restore_token;
    unsigned token_serial;
    char error[512];
};

static void set_error(ts_portal_t *p, const char *fmt, ...) {
    if (!p) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(p->error, sizeof(p->error), fmt, ap);
    va_end(ap);
}

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// ---------------------------------------------------------------------------
// Request object paths
// ---------------------------------------------------------------------------

int ts_portal_request_path(const char *unique_name, const char *token, char *out,
                           size_t out_len) {
    if (!unique_name || !token || !out || out_len == 0) return TS_PORTAL_ERR_ARGS;
    if (*token == '\0') return TS_PORTAL_ERR_ARGS;

    // ":1.42" becomes "1_42": the leading colon goes, dots become underscores,
    // because the result has to be a legal D-Bus object-path element.
    char sender[128];
    const char *p = unique_name;
    if (*p == ':') p++;
    if (*p == '\0') return TS_PORTAL_ERR_ARGS;
    size_t n = 0;
    for (; *p; p++) {
        if (n + 1 >= sizeof(sender)) return TS_PORTAL_ERR_ARGS;
        sender[n++] = (*p == '.') ? '_' : *p;
    }
    sender[n] = '\0';

    int written = snprintf(out, out_len, "%s/request/%s/%s", PORTAL_PATH, sender, token);
    if (written < 0 || (size_t)written >= out_len) return TS_PORTAL_ERR_ARGS;
    return TS_PORTAL_OK;
}

static void mint_token(ts_portal_t *p, char *out, size_t out_len) {
    // Unique within the process AND across processes: the object path is
    // namespaced by our unique bus name, but a token colliding with one from
    // an earlier session of the same name would cross wires. pid + counter is
    // enough and is what the reference implementations use.
    snprintf(out, out_len, "ts%d_%u", (int)getpid(), ++p->token_serial);
}

// ---------------------------------------------------------------------------
// Small libdbus helpers
//
// libdbus's convenience varargs API cannot build an a{sv}, so the options
// dicts every portal method takes have to go through the iterator API. These
// keep that from swamping the actual protocol below.
// ---------------------------------------------------------------------------

static int dict_open(DBusMessageIter *parent, DBusMessageIter *dict) {
    return dbus_message_iter_open_container(parent, DBUS_TYPE_ARRAY, "{sv}", dict);
}

static int dict_add_basic(DBusMessageIter *dict, const char *key, int type,
                          const char *signature, const void *value) {
    DBusMessageIter entry, variant;
    if (!dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry)) return 0;
    if (!dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key)) return 0;
    if (!dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, signature, &variant))
        return 0;
    if (!dbus_message_iter_append_basic(&variant, type, value)) return 0;
    if (!dbus_message_iter_close_container(&entry, &variant)) return 0;
    return dbus_message_iter_close_container(dict, &entry);
}

static int dict_add_string(DBusMessageIter *dict, const char *key, const char *value) {
    return dict_add_basic(dict, key, DBUS_TYPE_STRING, "s", &value);
}

static int dict_add_uint32(DBusMessageIter *dict, const char *key, uint32_t value) {
    dbus_uint32_t v = value;
    return dict_add_basic(dict, key, DBUS_TYPE_UINT32, "u", &v);
}

static int dict_add_boolean(DBusMessageIter *dict, const char *key, int value) {
    dbus_bool_t v = value ? TRUE : FALSE;
    return dict_add_basic(dict, key, DBUS_TYPE_BOOLEAN, "b", &v);
}

// Find `key` in an a{sv} the iterator is positioned at, leaving `out` on the
// variant's CONTENT. Returns 1 when found.
static int dict_find(DBusMessageIter *dict, const char *key, DBusMessageIter *out) {
    if (dbus_message_iter_get_arg_type(dict) != DBUS_TYPE_ARRAY) return 0;
    DBusMessageIter entries;
    dbus_message_iter_recurse(dict, &entries);
    while (dbus_message_iter_get_arg_type(&entries) == DBUS_TYPE_DICT_ENTRY) {
        DBusMessageIter entry;
        dbus_message_iter_recurse(&entries, &entry);
        const char *name = NULL;
        if (dbus_message_iter_get_arg_type(&entry) == DBUS_TYPE_STRING) {
            dbus_message_iter_get_basic(&entry, &name);
            if (name && strcmp(name, key) == 0) {
                dbus_message_iter_next(&entry);
                if (dbus_message_iter_get_arg_type(&entry) != DBUS_TYPE_VARIANT) return 0;
                dbus_message_iter_recurse(&entry, out);
                return 1;
            }
        }
        dbus_message_iter_next(&entries);
    }
    return 0;
}

static char *dup_string_at(DBusMessageIter *it) {
    int type = dbus_message_iter_get_arg_type(it);
    // Portals have shipped `session_handle` as both a string and an object
    // path over the years. Same bytes, different type code; accept either
    // rather than failing on a portal that is merely older than us.
    if (type != DBUS_TYPE_STRING && type != DBUS_TYPE_OBJECT_PATH) return NULL;
    const char *s = NULL;
    dbus_message_iter_get_basic(it, &s);
    return s ? strdup(s) : NULL;
}

// ---------------------------------------------------------------------------
// Waiting for a Response signal
// ---------------------------------------------------------------------------

typedef struct {
    char path[256];
    int got;
    DBusMessage *msg;
} response_wait_t;

static DBusHandlerResult response_filter(DBusConnection *conn, DBusMessage *msg, void *user) {
    (void)conn;
    response_wait_t *w = (response_wait_t *)user;
    if (w->got) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    if (!dbus_message_is_signal(msg, REQUEST_IFACE, "Response"))
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    const char *path = dbus_message_get_path(msg);
    if (!path || strcmp(path, w->path) != 0) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    w->msg = dbus_message_ref(msg);
    w->got = 1;
    return DBUS_HANDLER_RESULT_HANDLED;
}

static void watch_request_path(ts_portal_t *p, const char *path) {
    char rule[512];
    snprintf(rule, sizeof(rule),
             "type='signal',interface='" REQUEST_IFACE "',member='Response',path='%s'", path);
    // Non-blocking add: the rule is in flight, but the daemon processes it in
    // order ahead of anything our subsequent method call can provoke, so the
    // subscribe-before-call guarantee holds without a round trip.
    dbus_bus_add_match(p->conn, rule, NULL);
}

static void unwatch_request_path(ts_portal_t *p, const char *path) {
    char rule[512];
    snprintf(rule, sizeof(rule),
             "type='signal',interface='" REQUEST_IFACE "',member='Response',path='%s'", path);
    dbus_bus_remove_match(p->conn, rule, NULL);
}

// Run the connection until the Response lands or the deadline passes.
static int pump_until_response(ts_portal_t *p, response_wait_t *w, int timeout_ms) {
    int64_t deadline = now_ms() + timeout_ms;
    while (!w->got) {
        int64_t remaining = deadline - now_ms();
        if (remaining <= 0) {
            set_error(p, "no Response on %s within %dms", w->path, timeout_ms);
            return TS_PORTAL_ERR_TIMEOUT;
        }
        // Slice the wait so the deadline is honoured even when the bus is
        // quiet. 100ms is well below any human-scale timeout and costs
        // nothing while a consent dialog is on screen.
        int slice = remaining > 100 ? 100 : (int)remaining;
        if (!dbus_connection_read_write_dispatch(p->conn, slice)) {
            set_error(p, "session bus disconnected while waiting on %s", w->path);
            return TS_PORTAL_ERR_NO_BUS;
        }
    }
    return TS_PORTAL_OK;
}

// One portal call: subscribe, send, adopt the returned handle if it differs,
// wait, and hand back the Response's results iterator.
//
// On TS_PORTAL_OK the caller owns `*out_response` and must unref it.
static int portal_call(ts_portal_t *p, DBusMessage *call, const char *token, int timeout_ms,
                       DBusMessage **out_response) {
    *out_response = NULL;

    const char *unique = dbus_bus_get_unique_name(p->conn);
    if (!unique) {
        set_error(p, "no unique name on the session bus");
        return TS_PORTAL_ERR_NO_BUS;
    }

    response_wait_t wait;
    memset(&wait, 0, sizeof(wait));
    if (ts_portal_request_path(unique, token, wait.path, sizeof(wait.path)) != TS_PORTAL_OK) {
        set_error(p, "could not derive a request path for %s/%s", unique, token);
        return TS_PORTAL_ERR_PROTOCOL;
    }

    watch_request_path(p, wait.path);
    if (!dbus_connection_add_filter(p->conn, response_filter, &wait, NULL)) {
        unwatch_request_path(p, wait.path);
        set_error(p, "out of memory adding a D-Bus filter");
        return TS_PORTAL_ERR_PROTOCOL;
    }

    int rc = TS_PORTAL_OK;
    DBusError err;
    dbus_error_init(&err);
    DBusMessage *reply =
        dbus_connection_send_with_reply_and_block(p->conn, call, timeout_ms, &err);
    if (!reply) {
        if (dbus_error_has_name(&err, DBUS_ERROR_SERVICE_UNKNOWN)) {
            set_error(p, "no %s on the session bus (install xdg-desktop-portal)", PORTAL_BUS);
            rc = TS_PORTAL_ERR_NO_PORTAL;
        } else {
            set_error(p, "%s: %s", dbus_message_get_member(call),
                      err.message ? err.message : "call failed");
            rc = TS_PORTAL_ERR_PORTAL;
        }
        dbus_error_free(&err);
        goto done;
    }

    // The reply is the request handle, not the answer.
    {
        const char *handle = NULL;
        DBusMessageIter it;
        if (dbus_message_iter_init(reply, &it) &&
            dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_OBJECT_PATH) {
            dbus_message_iter_get_basic(&it, &handle);
        }
        if (handle && strcmp(handle, wait.path) != 0) {
            // Spec-mandated: the portal's handle wins. Subscribe to it too
            // rather than swapping, because the old subscription may already
            // have caught a signal in flight.
            watch_request_path(p, handle);
            snprintf(wait.path, sizeof(wait.path), "%s", handle);
        }
    }
    dbus_message_unref(reply);

    rc = pump_until_response(p, &wait, timeout_ms);
    if (rc != TS_PORTAL_OK) goto done;

    *out_response = wait.msg;
    wait.msg = NULL;

done:
    dbus_connection_remove_filter(p->conn, response_filter, &wait);
    unwatch_request_path(p, wait.path);
    if (wait.msg) dbus_message_unref(wait.msg);
    return rc;
}

// Split a Response signal into its code and a results iterator.
static int split_response(ts_portal_t *p, DBusMessage *msg, DBusMessageIter *results) {
    DBusMessageIter it;
    if (!dbus_message_iter_init(msg, &it) ||
        dbus_message_iter_get_arg_type(&it) != DBUS_TYPE_UINT32) {
        set_error(p, "Response signal had no response code");
        return TS_PORTAL_ERR_PROTOCOL;
    }
    dbus_uint32_t code = 0;
    dbus_message_iter_get_basic(&it, &code);
    dbus_message_iter_next(&it);
    *results = it;

    switch (code) {
        case 0:
            return TS_PORTAL_OK;
        case 1:
            // The user said no. Deliberately its own code: a sharer UI that
            // shows an error dialog because somebody declined to share their
            // screen is worse than one that shows nothing.
            set_error(p, "the user dismissed the screen-sharing dialog");
            return TS_PORTAL_ERR_CANCELLED;
        default:
            set_error(p, "the portal ended the request (response=%u)", (unsigned)code);
            return TS_PORTAL_ERR_PORTAL;
    }
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

ts_portal_t *ts_portal_new(void) {
    ts_portal_t *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    snprintf(p->error, sizeof(p->error), "no error");
    return p;
}

void ts_portal_close_session(ts_portal_t *p) {
    if (!p || !p->conn || !p->session_handle) return;
    // Closing the session is what makes the compositor drop its "your screen
    // is being shared" indicator. Leaking it leaves that on the user's panel
    // after the share ended, which reads as spyware.
    DBusMessage *call = dbus_message_new_method_call(PORTAL_BUS, p->session_handle,
                                                     SESSION_IFACE, "Close");
    if (call) {
        dbus_connection_send(p->conn, call, NULL);
        dbus_connection_flush(p->conn);
        dbus_message_unref(call);
    }
    free(p->session_handle);
    p->session_handle = NULL;
}

void ts_portal_free(ts_portal_t *p) {
    if (!p) return;
    ts_portal_close_session(p);
    if (p->conn) {
        // Private connections must be closed explicitly; unref alone leaks the
        // socket for the process's lifetime.
        dbus_connection_close(p->conn);
        dbus_connection_unref(p->conn);
    }
    free(p->restore_token);
    free(p);
}

int ts_portal_connect(ts_portal_t *p) {
    if (!p) return TS_PORTAL_ERR_ARGS;
    if (p->conn) return TS_PORTAL_OK;

    DBusError err;
    dbus_error_init(&err);
    // Private, not shared: a shared connection is process-global state that
    // other libraries also dispatch, and our filters would see their traffic
    // and vice versa.
    p->conn = dbus_bus_get_private(DBUS_BUS_SESSION, &err);
    if (!p->conn) {
        set_error(p, "no session bus: %s", err.message ? err.message : "unavailable");
        dbus_error_free(&err);
        return TS_PORTAL_ERR_NO_BUS;
    }
    // A library must not take the process down because the bus went away.
    dbus_connection_set_exit_on_disconnect(p->conn, FALSE);

    if (!dbus_bus_name_has_owner(p->conn, PORTAL_BUS, &err)) {
        set_error(p, "no %s on the session bus%s%s", PORTAL_BUS,
                  (err.message ? ": " : " (install xdg-desktop-portal)"),
                  err.message ? err.message : "");
        dbus_error_free(&err);
        return TS_PORTAL_ERR_NO_PORTAL;
    }
    dbus_error_free(&err);
    return TS_PORTAL_OK;
}

static uint32_t read_uint_property(ts_portal_t *p, const char *name) {
    if (!p || !p->conn) return 0;
    DBusMessage *call =
        dbus_message_new_method_call(PORTAL_BUS, PORTAL_PATH, PROPERTIES_IFACE, "Get");
    if (!call) return 0;
    const char *iface = SCREENCAST_IFACE;
    dbus_message_append_args(call, DBUS_TYPE_STRING, &iface, DBUS_TYPE_STRING, &name,
                             DBUS_TYPE_INVALID);
    DBusError err;
    dbus_error_init(&err);
    DBusMessage *reply = dbus_connection_send_with_reply_and_block(p->conn, call, 3000, &err);
    dbus_message_unref(call);
    if (!reply) {
        dbus_error_free(&err);
        return 0;
    }
    uint32_t value = 0;
    DBusMessageIter it, variant;
    if (dbus_message_iter_init(reply, &it) &&
        dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_VARIANT) {
        dbus_message_iter_recurse(&it, &variant);
        if (dbus_message_iter_get_arg_type(&variant) == DBUS_TYPE_UINT32) {
            dbus_uint32_t v = 0;
            dbus_message_iter_get_basic(&variant, &v);
            value = (uint32_t)v;
        }
    }
    dbus_message_unref(reply);
    return value;
}

uint32_t ts_portal_available_source_types(ts_portal_t *p) {
    return read_uint_property(p, "AvailableSourceTypes");
}

uint32_t ts_portal_available_cursor_modes(ts_portal_t *p) {
    return read_uint_property(p, "AvailableCursorModes");
}

const char *ts_portal_restore_token(const ts_portal_t *p) {
    return p ? p->restore_token : NULL;
}

const char *ts_portal_last_error(const ts_portal_t *p) {
    return p && p->error[0] ? p->error : "no error";
}

// ---------------------------------------------------------------------------
// The three-step handshake
// ---------------------------------------------------------------------------

static int do_create_session(ts_portal_t *p, int timeout_ms) {
    char handle_token[64], session_token[64];
    mint_token(p, handle_token, sizeof(handle_token));
    mint_token(p, session_token, sizeof(session_token));

    DBusMessage *call = dbus_message_new_method_call(PORTAL_BUS, PORTAL_PATH,
                                                     SCREENCAST_IFACE, "CreateSession");
    if (!call) return TS_PORTAL_ERR_PROTOCOL;
    DBusMessageIter args, dict;
    dbus_message_iter_init_append(call, &args);
    dict_open(&args, &dict);
    dict_add_string(&dict, "handle_token", handle_token);
    dict_add_string(&dict, "session_handle_token", session_token);
    dbus_message_iter_close_container(&args, &dict);

    DBusMessage *response = NULL;
    int rc = portal_call(p, call, handle_token, timeout_ms, &response);
    dbus_message_unref(call);
    if (rc != TS_PORTAL_OK) return rc;

    DBusMessageIter results;
    rc = split_response(p, response, &results);
    if (rc == TS_PORTAL_OK) {
        DBusMessageIter value;
        if (dict_find(&results, "session_handle", &value)) {
            free(p->session_handle);
            p->session_handle = dup_string_at(&value);
        }
        if (!p->session_handle) {
            set_error(p, "CreateSession returned no session_handle");
            rc = TS_PORTAL_ERR_PROTOCOL;
        }
    }
    dbus_message_unref(response);
    return rc;
}

static int do_select_sources(ts_portal_t *p, const ts_portal_request_t *req) {
    char handle_token[64];
    mint_token(p, handle_token, sizeof(handle_token));

    DBusMessage *call = dbus_message_new_method_call(PORTAL_BUS, PORTAL_PATH,
                                                     SCREENCAST_IFACE, "SelectSources");
    if (!call) return TS_PORTAL_ERR_PROTOCOL;
    DBusMessageIter args, dict;
    dbus_message_iter_init_append(call, &args);
    // The session handle travels as an OBJECT PATH here even though
    // CreateSession handed it back as a plain string. That asymmetry is in the
    // spec, not a bug being worked around.
    const char *session = p->session_handle;
    dbus_message_iter_append_basic(&args, DBUS_TYPE_OBJECT_PATH, &session);
    dict_open(&args, &dict);
    dict_add_string(&dict, "handle_token", handle_token);
    dict_add_uint32(&dict, "types", req->source_types);
    dict_add_boolean(&dict, "multiple", req->multiple);
    if (req->cursor_mode) dict_add_uint32(&dict, "cursor_mode", req->cursor_mode);
    if (req->persist_mode) dict_add_uint32(&dict, "persist_mode", req->persist_mode);
    if (req->restore_token && *req->restore_token)
        dict_add_string(&dict, "restore_token", req->restore_token);
    dbus_message_iter_close_container(&args, &dict);

    DBusMessage *response = NULL;
    int rc = portal_call(p, call, handle_token, req->timeout_ms, &response);
    dbus_message_unref(call);
    if (rc != TS_PORTAL_OK) return rc;

    DBusMessageIter results;
    rc = split_response(p, response, &results);
    dbus_message_unref(response);
    return rc;
}

// Parse `streams`: a(ua{sv}) — node id plus optional size/source_type props.
static int parse_streams(DBusMessageIter *value, ts_portal_stream_t *out, int max, int *count) {
    *count = 0;
    if (dbus_message_iter_get_arg_type(value) != DBUS_TYPE_ARRAY) return TS_PORTAL_ERR_PROTOCOL;
    DBusMessageIter array;
    dbus_message_iter_recurse(value, &array);
    while (dbus_message_iter_get_arg_type(&array) == DBUS_TYPE_STRUCT && *count < max) {
        DBusMessageIter entry;
        dbus_message_iter_recurse(&array, &entry);
        if (dbus_message_iter_get_arg_type(&entry) != DBUS_TYPE_UINT32)
            return TS_PORTAL_ERR_PROTOCOL;

        ts_portal_stream_t s;
        memset(&s, 0, sizeof(s));
        s.width = -1;
        s.height = -1;

        dbus_uint32_t node = 0;
        dbus_message_iter_get_basic(&entry, &node);
        s.node_id = (uint32_t)node;

        dbus_message_iter_next(&entry);
        DBusMessageIter prop;
        if (dict_find(&entry, "size", &prop) &&
            dbus_message_iter_get_arg_type(&prop) == DBUS_TYPE_STRUCT) {
            DBusMessageIter size;
            dbus_message_iter_recurse(&prop, &size);
            dbus_int32_t w = 0, h = 0;
            if (dbus_message_iter_get_arg_type(&size) == DBUS_TYPE_INT32) {
                dbus_message_iter_get_basic(&size, &w);
                dbus_message_iter_next(&size);
                if (dbus_message_iter_get_arg_type(&size) == DBUS_TYPE_INT32)
                    dbus_message_iter_get_basic(&size, &h);
            }
            s.width = w;
            s.height = h;
        }
        if (dict_find(&entry, "source_type", &prop) &&
            dbus_message_iter_get_arg_type(&prop) == DBUS_TYPE_UINT32) {
            dbus_uint32_t t = 0;
            dbus_message_iter_get_basic(&prop, &t);
            s.source_type = (uint32_t)t;
        }

        out[(*count)++] = s;
        dbus_message_iter_next(&array);
    }
    return TS_PORTAL_OK;
}

static int do_start(ts_portal_t *p, const ts_portal_request_t *req,
                    ts_portal_stream_t *out, int max, int *count) {
    char handle_token[64];
    mint_token(p, handle_token, sizeof(handle_token));

    DBusMessage *call =
        dbus_message_new_method_call(PORTAL_BUS, PORTAL_PATH, SCREENCAST_IFACE, "Start");
    if (!call) return TS_PORTAL_ERR_PROTOCOL;
    DBusMessageIter args, dict;
    dbus_message_iter_init_append(call, &args);
    const char *session = p->session_handle;
    dbus_message_iter_append_basic(&args, DBUS_TYPE_OBJECT_PATH, &session);
    // parent_window: an "x11:<xid>" or "wayland:<handle>" string parents the
    // dialog to our window. Empty is legal and means "unparented", which is
    // what a host with no window handle to offer must send.
    const char *parent = "";
    dbus_message_iter_append_basic(&args, DBUS_TYPE_STRING, &parent);
    dict_open(&args, &dict);
    dict_add_string(&dict, "handle_token", handle_token);
    dbus_message_iter_close_container(&args, &dict);

    DBusMessage *response = NULL;
    int rc = portal_call(p, call, handle_token, req->timeout_ms, &response);
    dbus_message_unref(call);
    if (rc != TS_PORTAL_OK) return rc;

    DBusMessageIter results;
    rc = split_response(p, response, &results);
    if (rc == TS_PORTAL_OK) {
        DBusMessageIter value;
        if (dict_find(&results, "restore_token", &value)) {
            free(p->restore_token);
            p->restore_token = dup_string_at(&value);
        }
        if (!dict_find(&results, "streams", &value)) {
            set_error(p, "Start succeeded but returned no streams");
            rc = TS_PORTAL_ERR_NO_STREAMS;
        } else {
            rc = parse_streams(&value, out, max, count);
            if (rc != TS_PORTAL_OK) {
                set_error(p, "could not parse the streams array");
            } else if (*count == 0) {
                set_error(p, "Start returned an empty streams array");
                rc = TS_PORTAL_ERR_NO_STREAMS;
            }
        }
    }
    dbus_message_unref(response);
    return rc;
}

int ts_portal_negotiate(ts_portal_t *p, const ts_portal_request_t *req,
                        ts_portal_stream_t *out_streams, int max_streams, int *out_count) {
    if (!p || !req || !out_streams || max_streams <= 0 || !out_count)
        return TS_PORTAL_ERR_ARGS;
    *out_count = 0;

    int rc = ts_portal_connect(p);
    if (rc != TS_PORTAL_OK) return rc;

    // CreateSession gets its own, short budget: it raises no UI, so a portal
    // that does not answer it quickly is broken rather than waiting on a
    // human. `req->timeout_ms` is the human-scale budget and belongs to the
    // two calls that can put something on screen.
    rc = do_create_session(p, req->timeout_ms > 5000 ? 5000 : req->timeout_ms);
    if (rc != TS_PORTAL_OK) return rc;

    rc = do_select_sources(p, req);
    if (rc != TS_PORTAL_OK) {
        ts_portal_close_session(p);
        return rc;
    }

    rc = do_start(p, req, out_streams, max_streams, out_count);
    if (rc != TS_PORTAL_OK) {
        ts_portal_close_session(p);
        return rc;
    }
    return TS_PORTAL_OK;
}

int ts_portal_open_pipewire_fd(ts_portal_t *p) {
    if (!p || !p->conn || !p->session_handle) {
        if (p) set_error(p, "no live portal session");
        return TS_PORTAL_ERR_ARGS;
    }
    // The one portal method that answers directly rather than through a
    // Request — there is nothing for a user to approve, the approval already
    // happened at Start.
    DBusMessage *call = dbus_message_new_method_call(PORTAL_BUS, PORTAL_PATH,
                                                     SCREENCAST_IFACE, "OpenPipeWireRemote");
    if (!call) return TS_PORTAL_ERR_PROTOCOL;
    DBusMessageIter args, dict;
    dbus_message_iter_init_append(call, &args);
    const char *session = p->session_handle;
    dbus_message_iter_append_basic(&args, DBUS_TYPE_OBJECT_PATH, &session);
    dict_open(&args, &dict);
    dbus_message_iter_close_container(&args, &dict);

    DBusError err;
    dbus_error_init(&err);
    DBusMessage *reply = dbus_connection_send_with_reply_and_block(p->conn, call, 5000, &err);
    dbus_message_unref(call);
    if (!reply) {
        set_error(p, "OpenPipeWireRemote: %s", err.message ? err.message : "call failed");
        dbus_error_free(&err);
        return TS_PORTAL_ERR_PORTAL;
    }

    int fd = -1;
    DBusMessageIter it;
    if (dbus_message_iter_init(reply, &it) &&
        dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_UNIX_FD) {
        // get_basic on a UNIX_FD hands back a DUP that we own. The message's
        // own copy dies with the unref below.
        dbus_message_iter_get_basic(&it, &fd);
    }
    dbus_message_unref(reply);

    if (fd < 0) {
        set_error(p, "OpenPipeWireRemote returned no file descriptor");
        return TS_PORTAL_ERR_PROTOCOL;
    }
    return fd;
}
