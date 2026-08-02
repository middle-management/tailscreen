#include "include/portalfakebus.h"

#include <dbus/dbus.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

// The fake ScreenCast service. See the header for what it does and does not
// prove.
//
// Deliberately NOT sharing CPortalCapture's request-path derivation. If both
// sides computed the path with the same function, a typo in it would move both
// sides together and the test would pass — the classic tautological fake. This
// one derives the path from the caller's unique name with its own small
// implementation, so the two have to agree independently. (The derivation is
// separately pinned against hand-written strings in the unit tests, which is
// the check neither side can perform on itself.)

#define PORTAL_BUS "org.freedesktop.portal.Desktop"
#define PORTAL_PATH "/org/freedesktop/portal/desktop"
#define SCREENCAST_IFACE "org.freedesktop.portal.ScreenCast"
#define REQUEST_IFACE "org.freedesktop.portal.Request"

struct ts_fakeportal {
    DBusConnection *conn;
    pthread_t thread;
    _Atomic int stop;
    _Atomic int started;
    _Atomic int calls;
    ts_fakeportal_config_t config;
    char error[256];
};

// Independent of ts_portal_request_path, on purpose. See the note above.
static void fake_request_path(const char *sender, const char *token, char *out, size_t len) {
    char clean[128];
    size_t n = 0;
    for (const char *p = sender; *p && n + 1 < sizeof(clean); p++) {
        if (*p == ':') continue;
        clean[n++] = (*p == '.') ? '_' : *p;
    }
    clean[n] = '\0';
    snprintf(out, len, PORTAL_PATH "/request/%s/%s", clean, token);
}

// ---------------------------------------------------------------------------
// Reading the options dict a client sent
// ---------------------------------------------------------------------------

static int options_string(DBusMessageIter *dict, const char *key, char *out, size_t len) {
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
                if (dbus_message_iter_get_arg_type(&entry) == DBUS_TYPE_VARIANT) {
                    DBusMessageIter variant;
                    dbus_message_iter_recurse(&entry, &variant);
                    if (dbus_message_iter_get_arg_type(&variant) == DBUS_TYPE_STRING) {
                        const char *value = NULL;
                        dbus_message_iter_get_basic(&variant, &value);
                        if (value) {
                            snprintf(out, len, "%s", value);
                            return 1;
                        }
                    }
                }
                return 0;
            }
        }
        dbus_message_iter_next(&entries);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Emitting Response
// ---------------------------------------------------------------------------

static void dict_add_string(DBusMessageIter *dict, const char *key, const char *value) {
    DBusMessageIter entry, variant;
    dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry);
    dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
    dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "s", &variant);
    dbus_message_iter_append_basic(&variant, DBUS_TYPE_STRING, &value);
    dbus_message_iter_close_container(&entry, &variant);
    dbus_message_iter_close_container(dict, &entry);
}

// The streams payload: a{sv} carrying `streams` of type a(ua{sv}).
static void append_streams(DBusMessageIter *results, const ts_fakeportal_config_t *cfg) {
    DBusMessageIter entry, variant, array, item, props, prop, pv, size;
    const char *key = "streams";

    dbus_message_iter_open_container(results, DBUS_TYPE_DICT_ENTRY, NULL, &entry);
    dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
    dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "a(ua{sv})", &variant);
    dbus_message_iter_open_container(&variant, DBUS_TYPE_ARRAY, "(ua{sv})", &array);

    dbus_message_iter_open_container(&array, DBUS_TYPE_STRUCT, NULL, &item);
    dbus_uint32_t node = cfg->node_id;
    dbus_message_iter_append_basic(&item, DBUS_TYPE_UINT32, &node);
    dbus_message_iter_open_container(&item, DBUS_TYPE_ARRAY, "{sv}", &props);

    // size: (ii)
    const char *size_key = "size";
    dbus_message_iter_open_container(&props, DBUS_TYPE_DICT_ENTRY, NULL, &prop);
    dbus_message_iter_append_basic(&prop, DBUS_TYPE_STRING, &size_key);
    dbus_message_iter_open_container(&prop, DBUS_TYPE_VARIANT, "(ii)", &pv);
    dbus_message_iter_open_container(&pv, DBUS_TYPE_STRUCT, NULL, &size);
    dbus_int32_t w = cfg->width, h = cfg->height;
    dbus_message_iter_append_basic(&size, DBUS_TYPE_INT32, &w);
    dbus_message_iter_append_basic(&size, DBUS_TYPE_INT32, &h);
    dbus_message_iter_close_container(&pv, &size);
    dbus_message_iter_close_container(&prop, &pv);
    dbus_message_iter_close_container(&props, &prop);

    // source_type: u
    const char *type_key = "source_type";
    dbus_message_iter_open_container(&props, DBUS_TYPE_DICT_ENTRY, NULL, &prop);
    dbus_message_iter_append_basic(&prop, DBUS_TYPE_STRING, &type_key);
    dbus_message_iter_open_container(&prop, DBUS_TYPE_VARIANT, "u", &pv);
    dbus_uint32_t st = cfg->source_type;
    dbus_message_iter_append_basic(&pv, DBUS_TYPE_UINT32, &st);
    dbus_message_iter_close_container(&prop, &pv);
    dbus_message_iter_close_container(&props, &prop);

    dbus_message_iter_close_container(&item, &props);
    dbus_message_iter_close_container(&array, &item);
    dbus_message_iter_close_container(&variant, &array);
    dbus_message_iter_close_container(&entry, &variant);
    dbus_message_iter_close_container(results, &entry);
}

typedef enum { RESULTS_NONE, RESULTS_SESSION, RESULTS_STREAMS } results_kind_t;

static void emit_response(ts_fakeportal_t *f, const char *path, uint32_t code,
                          results_kind_t kind, const char *session_handle) {
    DBusMessage *sig = dbus_message_new_signal(path, REQUEST_IFACE, "Response");
    if (!sig) return;
    DBusMessageIter args, results;
    dbus_message_iter_init_append(sig, &args);
    dbus_uint32_t c = code;
    dbus_message_iter_append_basic(&args, DBUS_TYPE_UINT32, &c);
    dbus_message_iter_open_container(&args, DBUS_TYPE_ARRAY, "{sv}", &results);
    if (kind == RESULTS_SESSION && session_handle) {
        dict_add_string(&results, "session_handle", session_handle);
    } else if (kind == RESULTS_STREAMS) {
        append_streams(&results, &f->config);
        if (f->config.offer_restore_token)
            dict_add_string(&results, "restore_token", "fake-restore-token");
    }
    dbus_message_iter_close_container(&args, &results);
    // Broadcast, no destination — so the client's match rule is what routes
    // it. A unicast signal would be delivered whether or not the client
    // subscribed, which would hide exactly the bug this fake is here to catch.
    dbus_connection_send(f->conn, sig, NULL);
    dbus_connection_flush(f->conn);
    dbus_message_unref(sig);
}

// Reply to the method call with the request object path, the way the real
// portal does.
static void reply_with_handle(ts_fakeportal_t *f, DBusMessage *msg, const char *path) {
    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (!reply) return;
    dbus_message_append_args(reply, DBUS_TYPE_OBJECT_PATH, &path, DBUS_TYPE_INVALID);
    dbus_connection_send(f->conn, reply, NULL);
    dbus_connection_flush(f->conn);
    dbus_message_unref(reply);
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

static DBusHandlerResult fake_filter(DBusConnection *conn, DBusMessage *msg, void *user) {
    (void)conn;
    ts_fakeportal_t *f = user;
    if (dbus_message_get_type(msg) != DBUS_MESSAGE_TYPE_METHOD_CALL)
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

    const char *sender = dbus_message_get_sender(msg);
    if (!sender) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

    if (dbus_message_is_method_call(msg, SCREENCAST_IFACE, "OpenPipeWireRemote")) {
        atomic_fetch_add(&f->calls, 1);
        // A socketpair end, not a pipe: it is the closest thing to what the
        // real portal hands over, and it makes the test's fstat meaningful.
        // The client owns its dup and closes it; ours goes with the message.
        int sv[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0)
            return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        DBusMessage *reply = dbus_message_new_method_return(msg);
        if (reply) {
            dbus_message_append_args(reply, DBUS_TYPE_UNIX_FD, &sv[0], DBUS_TYPE_INVALID);
            dbus_connection_send(f->conn, reply, NULL);
            dbus_connection_flush(f->conn);
            dbus_message_unref(reply);
        }
        close(sv[0]);
        close(sv[1]);
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    const char *member = NULL;
    results_kind_t kind = RESULTS_NONE;
    if (dbus_message_is_method_call(msg, SCREENCAST_IFACE, "CreateSession")) {
        member = "CreateSession";
        kind = RESULTS_SESSION;
    } else if (dbus_message_is_method_call(msg, SCREENCAST_IFACE, "SelectSources")) {
        member = "SelectSources";
    } else if (dbus_message_is_method_call(msg, SCREENCAST_IFACE, "Start")) {
        member = "Start";
        kind = RESULTS_STREAMS;
    } else {
        return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }
    atomic_fetch_add(&f->calls, 1);

    // The options dict is the LAST argument of every one of these, so walk to
    // the end rather than counting arguments per method.
    DBusMessageIter it;
    DBusMessageIter options;
    int have_options = 0;
    if (dbus_message_iter_init(msg, &it)) {
        do {
            if (dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_ARRAY) {
                options = it;
                have_options = 1;
            }
        } while (dbus_message_iter_next(&it));
    }

    char token[128] = "";
    char session_token[128] = "";
    if (have_options) {
        options_string(&options, "handle_token", token, sizeof(token));
        options_string(&options, "session_handle_token", session_token, sizeof(session_token));
    }
    if (token[0] == '\0') {
        // No handle_token means the client cannot possibly be listening on a
        // path we could guess, so failing loudly here is better than emitting
        // into the void.
        snprintf(f->error, sizeof(f->error), "%s arrived with no handle_token", member);
        DBusMessage *err = dbus_message_new_error(msg, DBUS_ERROR_INVALID_ARGS,
                                                  "missing handle_token");
        if (err) {
            dbus_connection_send(f->conn, err, NULL);
            dbus_connection_flush(f->conn);
            dbus_message_unref(err);
        }
        return DBUS_HANDLER_RESULT_HANDLED;
    }

    char path[256];
    fake_request_path(sender, token, path, sizeof(path));
    reply_with_handle(f, msg, path);

    char session_handle[256] = "";
    if (kind == RESULTS_SESSION) {
        char clean[128];
        size_t n = 0;
        for (const char *p = sender; *p && n + 1 < sizeof(clean); p++) {
            if (*p == ':') continue;
            clean[n++] = (*p == '.') ? '_' : *p;
        }
        clean[n] = '\0';
        snprintf(session_handle, sizeof(session_handle),
                 PORTAL_PATH "/session/%s/%s", clean,
                 session_token[0] ? session_token : "s");
    }

    uint32_t code = 0;
    if (kind == RESULTS_STREAMS) {
        if (f->config.start_answer == TS_FAKEPORTAL_ANSWER_CANCEL) code = 1;
        else if (f->config.start_answer == TS_FAKEPORTAL_ANSWER_ERROR) code = 2;
        if (code != 0) kind = RESULTS_NONE;
    }

    // Emitted immediately after the reply, with no pause. That is the tight
    // race the real protocol warns about: a client that subscribes after the
    // call returns misses this and waits forever.
    emit_response(f, path, code, kind, session_handle);
    return DBUS_HANDLER_RESULT_HANDLED;
}

static void *fake_thread(void *arg) {
    ts_fakeportal_t *f = arg;
    while (!atomic_load(&f->stop)) {
        if (!dbus_connection_read_write_dispatch(f->conn, 50)) break;
    }
    return NULL;
}

ts_fakeportal_t *ts_fakeportal_start(const ts_fakeportal_config_t *config) {
    if (!config) return NULL;
    ts_fakeportal_t *f = calloc(1, sizeof(*f));
    if (!f) return NULL;
    f->config = *config;

    DBusError err;
    dbus_error_init(&err);
    f->conn = dbus_bus_get_private(DBUS_BUS_SESSION, &err);
    if (!f->conn) {
        snprintf(f->error, sizeof(f->error), "no session bus: %s",
                 err.message ? err.message : "unavailable");
        dbus_error_free(&err);
        return f;
    }
    dbus_connection_set_exit_on_disconnect(f->conn, FALSE);

    // DO_NOT_QUEUE, never replace: on a machine with a real desktop the name
    // is already owned, and the fake must fail rather than displace the actual
    // consent authority. There is no flag combination here that steals it.
    int rc = dbus_bus_request_name(f->conn, PORTAL_BUS, DBUS_NAME_FLAG_DO_NOT_QUEUE, &err);
    if (rc != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER) {
        snprintf(f->error, sizeof(f->error),
                 "could not claim %s (a real portal is probably running): %s", PORTAL_BUS,
                 err.message ? err.message : "name taken");
        dbus_error_free(&err);
        dbus_connection_close(f->conn);
        dbus_connection_unref(f->conn);
        f->conn = NULL;
        return f;
    }
    dbus_error_free(&err);

    if (!dbus_connection_add_filter(f->conn, fake_filter, f, NULL)) {
        snprintf(f->error, sizeof(f->error), "could not install the fake portal's filter");
        return f;
    }
    if (pthread_create(&f->thread, NULL, fake_thread, f) != 0) {
        snprintf(f->error, sizeof(f->error), "could not start the fake portal's thread");
        return f;
    }
    atomic_store(&f->started, 1);
    snprintf(f->error, sizeof(f->error), "no error");
    return f;
}

void ts_fakeportal_stop(ts_fakeportal_t *f) {
    if (!f) return;
    if (atomic_load(&f->started)) {
        atomic_store(&f->stop, 1);
        pthread_join(f->thread, NULL);
    }
    if (f->conn) {
        dbus_connection_remove_filter(f->conn, fake_filter, f);
        dbus_connection_close(f->conn);
        dbus_connection_unref(f->conn);
    }
    free(f);
}

const char *ts_fakeportal_last_error(const ts_fakeportal_t *f) {
    if (!f) return "no fake portal";
    // `started` is the only reliable success signal: a fake that never claimed
    // the name still returns a handle, so callers must ask.
    return atomic_load((_Atomic int *)&f->started) ? "no error" : f->error;
}

int ts_fakeportal_call_count(const ts_fakeportal_t *f) {
    return f ? atomic_load((_Atomic int *)&f->calls) : 0;
}
