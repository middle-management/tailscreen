// Desktop notifications over `org.freedesktop.Notifications` (GDBus).
//
// The C part exists for one reason: every GDBus call that carries arguments
// goes through `g_variant_new`, which is VARIADIC and therefore uncallable from
// Swift. `Notify` in particular takes `(susssasa{sv}i)` — eight fields, two of
// them containers — and building that needs `GVariantBuilder`, which is a macro
// -shaped API on top of the same varargs. Everything above the wire (what to
// say, when, how to dedupe) is in `TailscreenProtocol` where Linux CI tests it.
//
// The same argument as PortalCaptureKit's shim, and the same split.
#ifndef TS_GNOTIFY_H
#define TS_GNOTIFY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ts_gnotify ts_gnotify;

/// A button on a posted notification was pressed. `action_key` is the key that
/// was supplied in `ts_gnotify_post`'s `actions`.
typedef void (*ts_gnotify_action_cb)(uint32_t id, const char *action_key, void *ctx);

/// A notification went away. `reason` is the freedesktop code: 1 expired,
/// 2 dismissed by the user, 3 closed by `ts_gnotify_withdraw`, 4 undefined.
typedef void (*ts_gnotify_closed_cb)(uint32_t id, uint32_t reason, void *ctx);

/// Connect to the session bus and read the daemon's capabilities.
///
/// Returns NULL when there is no session bus or no notification daemon on it —
/// a headless box, a minimal session, a container. That is a normal state to be
/// in, not an error to report: the caller keeps its in-window prompts and says
/// nothing.
///
/// **Call this from the thread whose GMainContext will be iterated.** GDBus
/// delivers signals to the thread-default main context captured at
/// subscription time, so a handle opened on a thread that never runs a main
/// loop posts fine and never reports a single button press. In the GTK app
/// that means the main thread; in a headless process it means whichever thread
/// runs the `GMainLoop`.
///
/// `desktop_entry` is the basename of the .desktop file (no extension), sent as
/// the `desktop-entry` hint so the daemon can find the app's icon and apply any
/// per-app rules the user has set. May be NULL.
ts_gnotify *ts_gnotify_open(const char *app_name, const char *desktop_entry);

/// Unsubscribe, drop the connection, free the handle. Safe on NULL.
void ts_gnotify_close(ts_gnotify *n);

/// Whether the daemon advertised `capability` in `GetCapabilities`.
///
/// The one that matters is **"actions"**. GNOME Shell and dunst advertise it;
/// several minimal daemons do not, and a daemon that does not advertise it
/// silently DROPS the buttons rather than failing the call. Posting an
/// Accept/Deny pair to one of those produces a banner that states a decision
/// and offers no way to make it — worse than a plain notification, because the
/// user waits for something that is not coming.
int ts_gnotify_has_capability(ts_gnotify *n, const char *capability);

/// Post a notification. Returns the daemon's id, or 0 on failure.
///
/// - `replaces_id`: 0 for a new notification, or a previous id to REPLACE it in
///   place. Replacing is what stops a re-post stacking a second copy.
/// - `actions`: NULL, or a NULL-terminated array of alternating key and label
///   — `{"approve", "Accept", "deny", "Deny", NULL}`. Ignored by daemons that
///   do not advertise the "actions" capability, so check first.
/// - `urgency`: freedesktop hint — 0 low, 1 normal, 2 critical. Critical is the
///   one that survives Do Not Disturb, and on most daemons it also never
///   expires on its own.
/// - `expire_timeout_ms`: -1 for the daemon's default, 0 for "never expire".
uint32_t ts_gnotify_post(ts_gnotify *n, uint32_t replaces_id, const char *summary,
                         const char *body, const char *const *actions, uint8_t urgency,
                         int32_t expire_timeout_ms);

/// Take a posted notification back off the screen.
///
/// The reason this exists: a banner reading "someone is waiting to be let in",
/// with an Accept button, is actively wrong once they have been let in from the
/// app window — pressing it then does nothing, or lands on whoever connects
/// next. A notice's life is tied to the thing it is about.
void ts_gnotify_withdraw(ts_gnotify *n, uint32_t id);

/// Install the signal callbacks. Either may be NULL. See `ts_gnotify_open` for
/// the thread they arrive on.
void ts_gnotify_set_callbacks(ts_gnotify *n, ts_gnotify_action_cb on_action,
                              ts_gnotify_closed_cb on_closed, void *ctx);

/// The last failure message, or NULL. Owned by the handle, valid until the next
/// call on it.
const char *ts_gnotify_last_error(ts_gnotify *n);

/// Why `ts_gnotify_open` returned NULL, for diagnostics. Static string.
const char *ts_gnotify_open_error(void);

#ifdef __cplusplus
}
#endif

#endif /* TS_GNOTIFY_H */
