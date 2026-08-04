// Desktop notifications on Windows, via the Windows App SDK's
// `AppNotificationManager`.
//
// The C part exists because **swift-winui does not project this API**. Its
// Swift surface covers `Microsoft.UI.*` and `Microsoft.Windows.AppLifecycle`,
// but not `Microsoft.Windows.AppNotifications` — so there is no
// `AppNotificationManager` and no `ToastNotificationManager` to call. What it
// ships instead is the C ABI header
// (`Sources/CWinRT/include/Microsoft.Windows.AppNotifications.h`), which this
// shim is written against: same interfaces, same vtable order, reached through
// `RoGetActivationFactory` the way `WGCCaptureKit` reaches Windows.Graphics.
//
// The split is GNotifyKit's, deliberately: this file owns the wire, and every
// decision — what to say, when, how to dedupe, when to withdraw — lives in
// `TailscreenProtocol`, where Linux CI tests it with no Windows in sight. The
// toast XML in particular is `WindowsToastPayload`'s: it is a string, and a
// string is testable anywhere.
//
// **Only the posting half is here.** A button press comes back through
// `Microsoft.Windows.AppLifecycle`'s `ExtendedActivationKind.AppNotification`,
// which swift-winui *does* project — so the host reads it in Swift and hands
// the argument string to `WindowsToastPayload.decodeArguments`. There is no
// callback, no event token and no COM handler object in this shim, which is
// what keeps it small.
#ifndef TS_WINNOTIFY_H
#define TS_WINNOTIFY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ts_winnotify ts_winnotify;

/// `AppNotificationSetting` — whether a posted toast will be SEEN.
///
/// This is the Windows answer to the question macOS asks with
/// `getNotificationSettings` and Linux asks with `GetCapabilities`: posting
/// still succeeds when the user has turned notifications off, it just goes
/// nowhere. A host that does not read this is a host whose approval prompts
/// silently stop arriving.
enum {
    TS_WINNOTIFY_SETTING_ENABLED = 0,
    TS_WINNOTIFY_SETTING_DISABLED_FOR_APPLICATION = 1,
    TS_WINNOTIFY_SETTING_DISABLED_FOR_USER = 2,
    TS_WINNOTIFY_SETTING_DISABLED_BY_GROUP_POLICY = 3,
    TS_WINNOTIFY_SETTING_DISABLED_BY_MANIFEST = 4,
    TS_WINNOTIFY_SETTING_UNSUPPORTED = 5,
    /// The query itself failed, or this is not Windows. Distinct from
    /// `UNSUPPORTED`, which is the platform's own answer.
    TS_WINNOTIFY_SETTING_UNKNOWN = 6
};

/// Register with the notification platform and return a handle.
///
/// Returns NULL when registration was refused — and **that is a normal state,
/// not an error to report.** `AppNotificationManager` works unpackaged, but
/// only with a Windows App Runtime it can reach: the zip build ships a
/// self-contained runtime whose Singleton package (the one the notification and
/// push APIs need) is deliberately not staged, so an unpackaged run can land
/// here legitimately. The caller keeps its in-window prompts and says so on the
/// share card, exactly as the Linux backend does when there is no notification
/// daemon.
///
/// That is the whole packaging fork, settled at RUNTIME rather than build time:
/// one code path, no flag, and a machine that cannot post says so on the
/// machine instead of in the release notes.
///
/// `display_name` is the name the toast is attributed to, for the unpackaged
/// case where there is no manifest to read one from. May be NULL, which falls
/// back to the no-argument `Register()` the packaged case wants anyway.
ts_winnotify *ts_winnotify_open(const char *display_name);

/// Unregister and free. Safe on NULL.
///
/// Unregistering matters more here than the symmetry suggests: the
/// registration installs a COM activator pointing at this executable, and one
/// left behind outlives the process.
void ts_winnotify_close(ts_winnotify *n);

/// The current `AppNotificationSetting`. Re-read rather than cached: a user can
/// turn notifications off in the middle of a share, which is the moment it
/// matters most.
int32_t ts_winnotify_setting(ts_winnotify *n);

/// Whether this desktop understands `scenario="urgent"` — the attribute that
/// breaks through Focus Assist.
///
/// It is a Windows 11 addition, and an unrecognized scenario is a SCHEMA
/// VIOLATION rather than a politely ignored hint: the payload is rejected and
/// nothing is posted at all. So the caller asks first and
/// `WindowsToastPayload.scenario` downgrades to `reminder`, which every build
/// understands. Read from `RtlGetVersion`, not `GetVersionEx`, which lies to an
/// unmanifested process.
int32_t ts_winnotify_supports_urgent(void);

/// Post `payload_xml` under `tag` within `group`. Returns the platform's
/// notification id, or 0 on failure.
///
/// Posting again under the same tag+group REPLACES the toast in place — the
/// Windows spelling of freedesktop's `replaces_id`, and what stops a re-post
/// stacking a second copy.
///
/// `high_priority` sets `AppNotificationPriority.High`, which is about
/// DELIVERY (it survives battery saver) and is a different axis from the
/// payload's `scenario`, which is about display. Both are spent only where
/// somebody is stuck.
uint32_t ts_winnotify_post(ts_winnotify *n, const char *payload_xml, const char *tag,
                           const char *group, int32_t high_priority);

/// Take a posted notification back off the screen, by the tag it was posted
/// under.
///
/// By tag rather than by id because the id is only knowable after `Show`
/// returned, and the reason to withdraw usually arrives from another thread:
/// a banner reading "someone is waiting to be let in", with an Accept button,
/// is actively wrong the moment they are admitted from the app window.
void ts_winnotify_withdraw(ts_winnotify *n, const char *tag, const char *group);

/// Clear every notification in `group`. What a share teardown calls, so a
/// stopped share leaves no answerable prompts behind.
void ts_winnotify_withdraw_group(ts_winnotify *n, const char *group);

/// The last failure, as text. Owned by the handle, valid until the next call on
/// it. NULL when nothing has failed.
const char *ts_winnotify_last_error(ts_winnotify *n);

/// Why `ts_winnotify_open` returned NULL, for the log. Static string.
const char *ts_winnotify_open_error(void);

/// Whether this build has a notification platform at all — 0 off Windows.
int32_t ts_winnotify_is_supported(void);

/// Read the activation `Argument` off an `AppNotificationActivatedEventArgs`.
///
/// **The one place the callback half needs C.** swift-winui projects
/// `AppInstance.Activated` and `ExtendedActivationKind.AppNotification`, so a
/// Swift host learns that a toast was pressed — but the event's `Data` is an
/// `AppNotificationActivatedEventArgs`, which is in the namespace swift-winui
/// does NOT project, so it arrives as an untyped `IInspectable` and the string
/// that says *which button, about whom* is behind one `QueryInterface` the
/// Swift side cannot spell.
///
/// `event_args` is that object's raw `IInspectable*` (`IUnknown.pUnk.borrow`,
/// which swift-winui exposes publicly). Borrowed, never released: the caller
/// still owns it.
///
/// Writes a NUL-terminated UTF-8 string into `out` and returns 1; returns 0
/// when this is not an `AppNotificationActivatedEventArgs`, which is the
/// ordinary case for every other activation kind the app is woken by.
int32_t ts_winnotify_activation_argument(void *event_args, char *out, int32_t capacity);

#ifdef __cplusplus
}
#endif

#endif /* TS_WINNOTIFY_H */
