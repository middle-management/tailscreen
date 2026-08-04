#include "include/ts_gnotify.h"

#include <gio/gio.h>
#include <glib.h>
#include <string.h>

#define TS_NOTIFY_NAME "org.freedesktop.Notifications"
#define TS_NOTIFY_PATH "/org/freedesktop/Notifications"
#define TS_NOTIFY_IFACE "org.freedesktop.Notifications"

/* Calls are synchronous, so a hung daemon must not hang the caller forever.
   Five seconds is far longer than any real answer and far shorter than a
   sharer noticing their app has stopped responding. */
#define TS_NOTIFY_TIMEOUT_MS 5000

struct ts_gnotify {
  GDBusConnection *connection;
  char *app_name;
  char *desktop_entry;
  /* NULL-terminated, from GetCapabilities. Read once at open: the set does not
     change while a daemon is running, and re-asking per post would put a
     synchronous round trip in front of every notification. */
  char **capabilities;
  guint action_subscription;
  guint closed_subscription;
  ts_gnotify_action_cb on_action;
  ts_gnotify_closed_cb on_closed;
  void *ctx;
  char *last_error;
};

static char ts_open_error[256];

static void ts_set_error(ts_gnotify *n, const char *message) {
  g_free(n->last_error);
  n->last_error = message ? g_strdup(message) : NULL;
}

static void ts_on_action(GDBusConnection *connection, const char *sender, const char *path,
                         const char *iface, const char *signal, GVariant *params,
                         gpointer user_data) {
  (void)connection;
  (void)sender;
  (void)path;
  (void)iface;
  (void)signal;
  ts_gnotify *n = user_data;
  if (!n->on_action) return;
  guint32 id = 0;
  const char *key = NULL;
  g_variant_get(params, "(u&s)", &id, &key);
  n->on_action(id, key ? key : "", n->ctx);
}

static void ts_on_closed(GDBusConnection *connection, const char *sender, const char *path,
                         const char *iface, const char *signal, GVariant *params,
                         gpointer user_data) {
  (void)connection;
  (void)sender;
  (void)path;
  (void)iface;
  (void)signal;
  ts_gnotify *n = user_data;
  if (!n->on_closed) return;
  guint32 id = 0;
  guint32 reason = 0;
  g_variant_get(params, "(uu)", &id, &reason);
  n->on_closed(id, reason, n->ctx);
}

ts_gnotify *ts_gnotify_open(const char *app_name, const char *desktop_entry) {
  ts_open_error[0] = '\0';

  GError *error = NULL;
  GDBusConnection *connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
  if (!connection) {
    g_snprintf(ts_open_error, sizeof(ts_open_error), "no session bus: %s",
               error ? error->message : "unknown");
    g_clear_error(&error);
    return NULL;
  }

  /* GetCapabilities doubles as the liveness probe. A daemon that cannot answer
     it is one that will not show anything either, and finding that out at open
     is what lets the host keep its in-window prompts instead of posting into a
     void. D-Bus activation may start a daemon in response to this call, which
     is the desired behaviour. */
  GVariant *reply = g_dbus_connection_call_sync(
      connection, TS_NOTIFY_NAME, TS_NOTIFY_PATH, TS_NOTIFY_IFACE, "GetCapabilities", NULL,
      G_VARIANT_TYPE("(as)"), G_DBUS_CALL_FLAGS_NONE, TS_NOTIFY_TIMEOUT_MS, NULL, &error);
  if (!reply) {
    g_snprintf(ts_open_error, sizeof(ts_open_error), "no notification daemon: %s",
               error ? error->message : "unknown");
    g_clear_error(&error);
    g_object_unref(connection);
    return NULL;
  }

  ts_gnotify *n = g_new0(ts_gnotify, 1);
  n->connection = connection;
  n->app_name = g_strdup(app_name ? app_name : "Tailscreen");
  n->desktop_entry = desktop_entry ? g_strdup(desktop_entry) : NULL;

  GVariant *capabilities = g_variant_get_child_value(reply, 0);
  n->capabilities = g_variant_dup_strv(capabilities, NULL);
  g_variant_unref(capabilities);
  g_variant_unref(reply);

  /* Subscribed here rather than lazily on the first post: a button pressed on
     the very first notification must be heard, and subscribing after the post
     loses that race. Both are filtered by interface AND path, so another
     app's notification ids cannot be mistaken for ours — the ids we get back
     from Notify are the only ones we act on anyway. */
  n->action_subscription = g_dbus_connection_signal_subscribe(
      connection, TS_NOTIFY_NAME, TS_NOTIFY_IFACE, "ActionInvoked", TS_NOTIFY_PATH, NULL,
      G_DBUS_SIGNAL_FLAGS_NONE, ts_on_action, n, NULL);
  n->closed_subscription = g_dbus_connection_signal_subscribe(
      connection, TS_NOTIFY_NAME, TS_NOTIFY_IFACE, "NotificationClosed", TS_NOTIFY_PATH, NULL,
      G_DBUS_SIGNAL_FLAGS_NONE, ts_on_closed, n, NULL);
  return n;
}

void ts_gnotify_close(ts_gnotify *n) {
  if (!n) return;
  if (n->action_subscription)
    g_dbus_connection_signal_unsubscribe(n->connection, n->action_subscription);
  if (n->closed_subscription)
    g_dbus_connection_signal_unsubscribe(n->connection, n->closed_subscription);
  g_clear_object(&n->connection);
  g_strfreev(n->capabilities);
  g_free(n->app_name);
  g_free(n->desktop_entry);
  g_free(n->last_error);
  g_free(n);
}

int ts_gnotify_has_capability(ts_gnotify *n, const char *capability) {
  if (!n || !n->capabilities || !capability) return 0;
  for (char **it = n->capabilities; *it; ++it) {
    if (g_strcmp0(*it, capability) == 0) return 1;
  }
  return 0;
}

void ts_gnotify_set_callbacks(ts_gnotify *n, ts_gnotify_action_cb on_action,
                              ts_gnotify_closed_cb on_closed, void *ctx) {
  if (!n) return;
  n->on_action = on_action;
  n->on_closed = on_closed;
  n->ctx = ctx;
}

uint32_t ts_gnotify_post(ts_gnotify *n, uint32_t replaces_id, const char *summary,
                         const char *body, const char *const *actions, uint8_t urgency,
                         int32_t expire_timeout_ms) {
  if (!n) return 0;
  ts_set_error(n, NULL);

  GVariantBuilder action_builder;
  g_variant_builder_init(&action_builder, G_VARIANT_TYPE("as"));
  if (actions) {
    /* Alternating key,label. An odd-length array would make the daemon read a
       label as the next key, so a trailing unpaired entry is dropped rather
       than sent — the spec has no way to express half an action. */
    for (const char *const *it = actions; it[0] && it[1]; it += 2) {
      g_variant_builder_add(&action_builder, "s", it[0]);
      g_variant_builder_add(&action_builder, "s", it[1]);
    }
  }

  GVariantBuilder hints;
  g_variant_builder_init(&hints, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&hints, "{sv}", "urgency", g_variant_new_byte(urgency));
  if (n->desktop_entry) {
    g_variant_builder_add(&hints, "{sv}", "desktop-entry",
                          g_variant_new_string(n->desktop_entry));
  }

  GError *error = NULL;
  GVariant *reply = g_dbus_connection_call_sync(
      n->connection, TS_NOTIFY_NAME, TS_NOTIFY_PATH, TS_NOTIFY_IFACE, "Notify",
      g_variant_new("(susssasa{sv}i)", n->app_name, replaces_id, "", summary ? summary : "",
                    body ? body : "", &action_builder, &hints, expire_timeout_ms),
      G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, TS_NOTIFY_TIMEOUT_MS, NULL, &error);
  if (!reply) {
    ts_set_error(n, error ? error->message : "Notify failed");
    g_clear_error(&error);
    return 0;
  }
  guint32 id = 0;
  g_variant_get(reply, "(u)", &id);
  g_variant_unref(reply);
  return id;
}

void ts_gnotify_withdraw(ts_gnotify *n, uint32_t id) {
  if (!n || id == 0) return;
  ts_set_error(n, NULL);
  GError *error = NULL;
  GVariant *reply = g_dbus_connection_call_sync(
      n->connection, TS_NOTIFY_NAME, TS_NOTIFY_PATH, TS_NOTIFY_IFACE, "CloseNotification",
      g_variant_new("(u)", id), NULL, G_DBUS_CALL_FLAGS_NONE, TS_NOTIFY_TIMEOUT_MS, NULL,
      &error);
  if (!reply) {
    /* Not worth surfacing beyond the error slot: the usual cause is that the
       notification already expired, which is the state we wanted anyway. */
    ts_set_error(n, error ? error->message : "CloseNotification failed");
    g_clear_error(&error);
    return;
  }
  g_variant_unref(reply);
}

const char *ts_gnotify_last_error(ts_gnotify *n) { return n ? n->last_error : NULL; }

const char *ts_gnotify_open_error(void) {
  return ts_open_error[0] ? ts_open_error : NULL;
}
