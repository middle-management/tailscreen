#include "include/ts_winnotify.h"

/* For NULL. A compiler-provided header, not part of MSVC's STL — see the note
 * in CSendInput about why no STL header may appear in a file MSVC compiles. */
#include <stddef.h>

#if defined(_WIN32)

#define WIN32_LEAN_AND_MEAN

#include <windows.h>

/* EventRegistrationToken, for the two `NotificationInvoked` vtable slots this
 * shim does not call but must not omit — see the comment on them. */
#include <eventtoken.h>
#include <inspectable.h>
#include <roapi.h>
#include <unknwn.h>
#include <winstring.h>

/* ------------------------------------------------------------------------
 * The Microsoft.Windows.AppNotifications ABI, declared by hand.
 *
 * Not included from a header, because there is no header to include: this is
 * Windows App SDK, not the Windows SDK, so `windows.ui.notifications.h` is the
 * wrong API and nothing in the platform SDK declares the right one. What the
 * repo does have is swift-winui's C ABI projection at
 * `Apps/windows/.build/checkouts/swift-winui/Sources/CWinRT/include/Microsoft.Windows.AppNotifications.h`,
 * which is what the vtables below were transcribed from — same interfaces,
 * same method ORDER, which is the part that matters, since a vtable is
 * position-addressed and a method inserted in the wrong slot calls its
 * neighbour with the wrong arguments.
 *
 * Only the methods this shim reaches are named; the ones after them are
 * omitted, which is safe precisely because the order up to that point is the
 * contract. Everything before `Register` is `IInspectable`.
 *
 * That header declares the IIDs (`EXTERN_C const IID IID___x_ABI_…`) without
 * defining them — they resolve from the Windows App SDK's own libraries, which
 * this package does not link. So they are spelled out below, read out of the
 * GuidAttribute rows of `lib/uap10.0/Microsoft.Windows.AppNotifications.winmd`
 * in Microsoft.WindowsAppSDK 1.5.250108004 — the same package
 * `scripts/windows/stage-winappsdk.sh` stages, pinned to the same version. The
 * ten interfaces in that winmd are exactly the ten in swift-winui's header,
 * name for name, which is the cross-check that they were read correctly.
 * ------------------------------------------------------------------------ */

typedef struct TSNotification TSNotification;
typedef struct TSNotificationFactory TSNotificationFactory;
typedef struct TSNotificationManager TSNotificationManager;
typedef struct TSNotificationManager2 TSNotificationManager2;
typedef struct TSNotificationManagerStatics TSNotificationManagerStatics;
typedef struct TSActivatedEventArgs TSActivatedEventArgs;

#define TS_IINSPECTABLE_METHODS(T)                                              \
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(T *, REFIID, void **);           \
    ULONG(STDMETHODCALLTYPE *AddRef)(T *);                                      \
    ULONG(STDMETHODCALLTYPE *Release)(T *);                                     \
    HRESULT(STDMETHODCALLTYPE *GetIids)(T *, ULONG *, IID **);                  \
    HRESULT(STDMETHODCALLTYPE *GetRuntimeClassName)(T *, HSTRING *);            \
    HRESULT(STDMETHODCALLTYPE *GetTrustLevel)(T *, TrustLevel *)

typedef struct TSNotificationVtbl {
    TS_IINSPECTABLE_METHODS(TSNotification);
    HRESULT(STDMETHODCALLTYPE *get_Tag)(TSNotification *, HSTRING *);
    HRESULT(STDMETHODCALLTYPE *put_Tag)(TSNotification *, HSTRING);
    HRESULT(STDMETHODCALLTYPE *get_Group)(TSNotification *, HSTRING *);
    HRESULT(STDMETHODCALLTYPE *put_Group)(TSNotification *, HSTRING);
    HRESULT(STDMETHODCALLTYPE *get_Id)(TSNotification *, UINT32 *);
    HRESULT(STDMETHODCALLTYPE *get_Payload)(TSNotification *, HSTRING *);
    HRESULT(STDMETHODCALLTYPE *get_Progress)(TSNotification *, void **);
    HRESULT(STDMETHODCALLTYPE *put_Progress)(TSNotification *, void *);
    /* Windows.Foundation.DateTime is one INT64, passed by value. Declared as
     * INT64 rather than pulled in from windows.foundation.h so this file needs
     * no WinRT C++ headers at all. */
    HRESULT(STDMETHODCALLTYPE *get_Expiration)(TSNotification *, INT64 *);
    HRESULT(STDMETHODCALLTYPE *put_Expiration)(TSNotification *, INT64);
    HRESULT(STDMETHODCALLTYPE *get_ExpiresOnReboot)(TSNotification *, boolean *);
    HRESULT(STDMETHODCALLTYPE *put_ExpiresOnReboot)(TSNotification *, boolean);
    HRESULT(STDMETHODCALLTYPE *get_Priority)(TSNotification *, int *);
    HRESULT(STDMETHODCALLTYPE *put_Priority)(TSNotification *, int);
} TSNotificationVtbl;
struct TSNotification {
    const TSNotificationVtbl *lpVtbl;
};

typedef struct TSNotificationFactoryVtbl {
    TS_IINSPECTABLE_METHODS(TSNotificationFactory);
    HRESULT(STDMETHODCALLTYPE *CreateInstance)(TSNotificationFactory *, HSTRING,
                                               TSNotification **);
} TSNotificationFactoryVtbl;
struct TSNotificationFactory {
    const TSNotificationFactoryVtbl *lpVtbl;
};

typedef struct TSNotificationManagerVtbl {
    TS_IINSPECTABLE_METHODS(TSNotificationManager);
    HRESULT(STDMETHODCALLTYPE *Register)(TSNotificationManager *);
    HRESULT(STDMETHODCALLTYPE *Unregister)(TSNotificationManager *);
    HRESULT(STDMETHODCALLTYPE *UnregisterAll)(TSNotificationManager *);
    /* add_/remove_NotificationInvoked: unused — the activation comes back
     * through AppLifecycle in Swift, not through a handler here. Their slots
     * still have to exist, or every method below shifts up by two. */
    HRESULT(STDMETHODCALLTYPE *add_NotificationInvoked)(TSNotificationManager *, void *,
                                                        EventRegistrationToken *);
    HRESULT(STDMETHODCALLTYPE *remove_NotificationInvoked)(TSNotificationManager *,
                                                           EventRegistrationToken);
    HRESULT(STDMETHODCALLTYPE *Show)(TSNotificationManager *, TSNotification *);
    HRESULT(STDMETHODCALLTYPE *UpdateAsync)(TSNotificationManager *, void *, HSTRING, HSTRING,
                                            void **);
    HRESULT(STDMETHODCALLTYPE *UpdateAsync2)(TSNotificationManager *, void *, HSTRING, void **);
    HRESULT(STDMETHODCALLTYPE *get_Setting)(TSNotificationManager *, int *);
    HRESULT(STDMETHODCALLTYPE *RemoveByIdAsync)(TSNotificationManager *, UINT32, IUnknown **);
    HRESULT(STDMETHODCALLTYPE *RemoveByTagAsync)(TSNotificationManager *, HSTRING, IUnknown **);
    HRESULT(STDMETHODCALLTYPE *RemoveByTagAndGroupAsync)(TSNotificationManager *, HSTRING, HSTRING,
                                                         IUnknown **);
    HRESULT(STDMETHODCALLTYPE *RemoveByGroupAsync)(TSNotificationManager *, HSTRING, IUnknown **);
    HRESULT(STDMETHODCALLTYPE *RemoveAllAsync)(TSNotificationManager *, IUnknown **);
} TSNotificationManagerVtbl;
struct TSNotificationManager {
    const TSNotificationManagerVtbl *lpVtbl;
};

typedef struct TSNotificationManager2Vtbl {
    TS_IINSPECTABLE_METHODS(TSNotificationManager2);
    /* The unpackaged-friendly overload: it is what puts a name and an icon on
     * a toast that has no manifest to read them from. `iconUri` is an
     * IUriRuntimeClass* and NULL is accepted — which is the point of using it,
     * since constructing a Uri would mean a second activation factory for one
     * optional argument. */
    HRESULT(STDMETHODCALLTYPE *Register)(TSNotificationManager2 *, HSTRING, void *);
} TSNotificationManager2Vtbl;
struct TSNotificationManager2 {
    const TSNotificationManager2Vtbl *lpVtbl;
};

typedef struct TSActivatedEventArgsVtbl {
    TS_IINSPECTABLE_METHODS(TSActivatedEventArgs);
    HRESULT(STDMETHODCALLTYPE *get_Argument)(TSActivatedEventArgs *, HSTRING *);
    HRESULT(STDMETHODCALLTYPE *get_UserInput)(TSActivatedEventArgs *, void **);
} TSActivatedEventArgsVtbl;
struct TSActivatedEventArgs {
    const TSActivatedEventArgsVtbl *lpVtbl;
};

typedef struct TSNotificationManagerStaticsVtbl {
    TS_IINSPECTABLE_METHODS(TSNotificationManagerStatics);
    HRESULT(STDMETHODCALLTYPE *get_Default)(TSNotificationManagerStatics *,
                                            TSNotificationManager **);
} TSNotificationManagerStaticsVtbl;
struct TSNotificationManagerStatics {
    const TSNotificationManagerStaticsVtbl *lpVtbl;
};

/* Only the IIDs this shim actually asks for. `IAppNotificationManager`
 * (55129688-b4bd-550b-ae6b-c24061954d91) and `IAppNotificationManagerStatics2`
 * (6eb42a35-e82f-5732-98f1-129705602f2e) are deliberately absent: the manager
 * arrives already typed from `get_Default`, and `IsSupported` would only
 * restate what a failed `Register` already says. */
/* 38ba268d-e0c7-522e-a79d-8a29dcdd7135 */
static const GUID TS_IID_AppNotificationManager2 = {
    0x38ba268d, 0xe0c7, 0x522e, {0xa7, 0x9d, 0x8a, 0x29, 0xdc, 0xdd, 0x71, 0x35}};
/* 6cfc0d8d-84a3-5592-b4c6-e3e7e7c680e4 */
static const GUID TS_IID_AppNotificationManagerStatics = {
    0x6cfc0d8d, 0x84a3, 0x5592, {0xb4, 0xc6, 0xe3, 0xe7, 0xe7, 0xc6, 0x80, 0xe4}};
/* 7a8afaf9-31cb-51d5-82be-db6bd5878b77 */
static const GUID TS_IID_AppNotificationActivatedEventArgs = {
    0x7a8afaf9, 0x31cb, 0x51d5, {0x82, 0xbe, 0xdb, 0x6b, 0xd5, 0x87, 0x8b, 0x77}};
/* 9ffee485-184a-5c65-87a9-c1d94469dbe7 */
static const GUID TS_IID_AppNotificationFactory = {
    0x9ffee485, 0x184a, 0x5c65, {0x87, 0xa9, 0xc1, 0xd9, 0x44, 0x69, 0xdb, 0xe7}};

static const wchar_t kManagerClass[] = L"Microsoft.Windows.AppNotifications.AppNotificationManager";
static const wchar_t kNotificationClass[] = L"Microsoft.Windows.AppNotifications.AppNotification";

/* AppNotificationPriority. */
#define TS_PRIORITY_DEFAULT 0
#define TS_PRIORITY_HIGH 1

/* ------------------------------------------------------------------------ */

struct ts_winnotify {
    TSNotificationManager *manager;
    TSNotificationFactory *factory;
    char error[256];
    int has_error;
};

static char g_open_error[256];

static void ts_set_open_error(const char *message, HRESULT hr) {
    /* `%.200s` into a 256-byte buffer, so the precision is what bounds this
     * rather than the buffer — wsprintfA has no size argument to give it. */
    wsprintfA(g_open_error, "%.200s (0x%08lX)", message, (unsigned long)hr);
}

static void ts_set_error(ts_winnotify *n, const char *message, HRESULT hr) {
    if (!n) return;
    wsprintfA(n->error, "%.200s (0x%08lX)", message, (unsigned long)hr);
    n->has_error = 1;
}

/// WinRT needs an initialised apartment on the calling thread. S_FALSE means
/// already initialised the way we asked; RPC_E_CHANGED_MODE means someone else
/// chose, and these interfaces work either way — so neither is fatal, and
/// neither is ours to undo.
///
/// Called on the way into every entry point rather than once at open, because
/// the host is free to post from a thread that never initialised one — a
/// notice fires off whatever thread noticed a viewer arrive. The cost is one
/// already-initialised return; the alternative is `CO_E_NOTINITIALIZED` on a
/// path that only some callers take.
static void ts_ensure_apartment(void) { RoInitialize(RO_INIT_MULTITHREADED); }

/// UTF-8 -> HSTRING. Returns NULL for NULL, which every caller treats as "no
/// value" rather than as an error.
static HSTRING ts_hstring(const char *utf8) {
    int wide_len;
    wchar_t *wide;
    HSTRING out = NULL;
    HRESULT hr;

    if (!utf8) return NULL;
    wide_len = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    if (wide_len <= 0) return NULL;
    wide = (wchar_t *)HeapAlloc(GetProcessHeap(), 0, (SIZE_T)wide_len * sizeof(wchar_t));
    if (!wide) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, wide_len) <= 0) {
        HeapFree(GetProcessHeap(), 0, wide);
        return NULL;
    }
    /* wide_len counts the terminator; WindowsCreateString must not. */
    hr = WindowsCreateString(wide, (UINT32)(wide_len - 1), &out);
    HeapFree(GetProcessHeap(), 0, wide);
    return SUCCEEDED(hr) ? out : NULL;
}

static HRESULT ts_activation_factory(const wchar_t *name, REFIID iid, void **out) {
    HSTRING class_name = NULL;
    HRESULT hr = WindowsCreateString(name, (UINT32)lstrlenW(name), &class_name);
    if (FAILED(hr)) return hr;
    hr = RoGetActivationFactory(class_name, iid, out);
    WindowsDeleteString(class_name);
    return hr;
}

ts_winnotify *ts_winnotify_open(const char *display_name) {
    ts_winnotify *n;
    TSNotificationManagerStatics *statics = NULL;
    TSNotificationManager *manager = NULL;
    TSNotificationManager2 *manager2 = NULL;
    TSNotificationFactory *factory = NULL;
    HRESULT hr;

    g_open_error[0] = '\0';
    ts_ensure_apartment();

    hr = ts_activation_factory(kManagerClass, &TS_IID_AppNotificationManagerStatics,
                               (void **)&statics);
    if (FAILED(hr) || !statics) {
        /* The ordinary unpackaged failure: no Windows App Runtime the process
         * can reach, so the runtime class does not resolve. Normal, not an
         * error to show anybody. */
        ts_set_open_error("no Windows App SDK notification platform", hr);
        return NULL;
    }

    hr = statics->lpVtbl->get_Default(statics, &manager);
    statics->lpVtbl->Release(statics);
    if (FAILED(hr) || !manager) {
        ts_set_open_error("AppNotificationManager.Default unavailable", hr);
        return NULL;
    }

    /* Register() is what installs the COM activator this process is reached
     * through when a button is pressed. Without it a toast can still be shown
     * and its buttons do nothing — the failure this whole runtime-probe design
     * exists to turn into a visible one. */
    hr = E_FAIL;
    if (display_name) {
        HRESULT qi = manager->lpVtbl->QueryInterface(manager, &TS_IID_AppNotificationManager2,
                                                     (void **)&manager2);
        if (SUCCEEDED(qi) && manager2) {
            HSTRING name = ts_hstring(display_name);
            hr = manager2->lpVtbl->Register(manager2, name, NULL);
            if (name) WindowsDeleteString(name);
            manager2->lpVtbl->Release(manager2);
        }
    }
    if (FAILED(hr)) {
        /* Either no display name was asked for, or this runtime predates the
         * two-argument overload. The packaged case wants this one anyway: the
         * manifest already carries the name and the icon. */
        hr = manager->lpVtbl->Register(manager);
    }
    if (FAILED(hr)) {
        ts_set_open_error("AppNotificationManager.Register refused", hr);
        manager->lpVtbl->Release(manager);
        return NULL;
    }

    hr = ts_activation_factory(kNotificationClass, &TS_IID_AppNotificationFactory,
                               (void **)&factory);
    if (FAILED(hr) || !factory) {
        ts_set_open_error("AppNotification factory unavailable", hr);
        manager->lpVtbl->Unregister(manager);
        manager->lpVtbl->Release(manager);
        return NULL;
    }

    n = (ts_winnotify *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(ts_winnotify));
    if (!n) {
        ts_set_open_error("out of memory", E_OUTOFMEMORY);
        factory->lpVtbl->Release(factory);
        manager->lpVtbl->Unregister(manager);
        manager->lpVtbl->Release(manager);
        return NULL;
    }
    n->manager = manager;
    n->factory = factory;
    return n;
}

void ts_winnotify_close(ts_winnotify *n) {
    if (!n) return;
    if (n->factory) n->factory->lpVtbl->Release(n->factory);
    if (n->manager) {
        /* Unregister before Release: the activator registration names this
         * executable, and one left behind outlives the process. */
        n->manager->lpVtbl->Unregister(n->manager);
        n->manager->lpVtbl->Release(n->manager);
    }
    HeapFree(GetProcessHeap(), 0, n);
}

int32_t ts_winnotify_setting(ts_winnotify *n) {
    int value = 0;
    HRESULT hr;
    if (!n || !n->manager) return TS_WINNOTIFY_SETTING_UNKNOWN;
    hr = n->manager->lpVtbl->get_Setting(n->manager, &value);
    if (FAILED(hr)) {
        ts_set_error(n, "AppNotificationManager.Setting failed", hr);
        return TS_WINNOTIFY_SETTING_UNKNOWN;
    }
    if (value < TS_WINNOTIFY_SETTING_ENABLED || value > TS_WINNOTIFY_SETTING_UNSUPPORTED) {
        return TS_WINNOTIFY_SETTING_UNKNOWN;
    }
    return (int32_t)value;
}

int32_t ts_winnotify_supports_urgent(void) {
    /* RtlGetVersion, not GetVersionEx: the documented API reports 6.2 to a
     * process without a compatibility manifest, which would make every Windows
     * 11 desktop look like Windows 8 and permanently downgrade the scenario. */
    typedef LONG(WINAPI * RtlGetVersionFn)(PRTL_OSVERSIONINFOW);
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    RtlGetVersionFn get_version;
    RTL_OSVERSIONINFOW info;

    if (!ntdll) return 0;
    get_version = (RtlGetVersionFn)(void *)GetProcAddress(ntdll, "RtlGetVersion");
    if (!get_version) return 0;

    ZeroMemory(&info, sizeof(info));
    info.dwOSVersionInfoSize = sizeof(info);
    if (get_version(&info) != 0) return 0;
    /* Windows 11 is 10.0.22000. `scenario="urgent"` arrived with it. */
    return (info.dwMajorVersion > 10
            || (info.dwMajorVersion == 10 && info.dwBuildNumber >= 22000))
               ? 1
               : 0;
}

uint32_t ts_winnotify_post(ts_winnotify *n, const char *payload_xml, const char *tag,
                           const char *group, int32_t high_priority) {
    TSNotification *notification = NULL;
    HSTRING payload = NULL;
    HSTRING tag_string = NULL;
    HSTRING group_string = NULL;
    UINT32 id = 0;
    HRESULT hr;

    if (!n || !n->manager || !n->factory || !payload_xml) return 0;
    ts_ensure_apartment();

    payload = ts_hstring(payload_xml);
    if (!payload) {
        ts_set_error(n, "payload could not be converted to UTF-16", E_INVALIDARG);
        return 0;
    }
    hr = n->factory->lpVtbl->CreateInstance(n->factory, payload, &notification);
    WindowsDeleteString(payload);
    if (FAILED(hr) || !notification) {
        /* The XML did not parse. `WindowsToastPayload` escapes for exactly
         * this — a peer whose hostname carries an `&` would land here, and
         * only that peer's notice would ever be missing. */
        ts_set_error(n, "AppNotification payload rejected", hr);
        return 0;
    }

    if (tag) {
        tag_string = ts_hstring(tag);
        if (tag_string) {
            notification->lpVtbl->put_Tag(notification, tag_string);
            WindowsDeleteString(tag_string);
        }
    }
    if (group) {
        group_string = ts_hstring(group);
        if (group_string) {
            notification->lpVtbl->put_Group(notification, group_string);
            WindowsDeleteString(group_string);
        }
    }
    notification->lpVtbl->put_Priority(notification,
                                       high_priority ? TS_PRIORITY_HIGH : TS_PRIORITY_DEFAULT);

    hr = n->manager->lpVtbl->Show(n->manager, notification);
    if (FAILED(hr)) {
        ts_set_error(n, "AppNotificationManager.Show failed", hr);
        notification->lpVtbl->Release(notification);
        return 0;
    }
    /* Id is assigned by Show. Zero would mean "not posted" to the caller, so a
     * platform that hands back zero anyway is reported as the failure it is
     * indistinguishable from. */
    if (FAILED(notification->lpVtbl->get_Id(notification, &id))) id = 0;
    notification->lpVtbl->Release(notification);
    return (uint32_t)id;
}

void ts_winnotify_withdraw(ts_winnotify *n, const char *tag, const char *group) {
    HSTRING tag_string;
    HSTRING group_string;
    IUnknown *operation = NULL;
    HRESULT hr;

    if (!n || !n->manager || !tag) return;
    ts_ensure_apartment();
    tag_string = ts_hstring(tag);
    if (!tag_string) return;
    group_string = ts_hstring(group);

    if (group_string) {
        hr = n->manager->lpVtbl->RemoveByTagAndGroupAsync(n->manager, tag_string, group_string,
                                                          &operation);
    } else {
        hr = n->manager->lpVtbl->RemoveByTagAsync(n->manager, tag_string, &operation);
    }
    WindowsDeleteString(tag_string);
    if (group_string) WindowsDeleteString(group_string);
    if (FAILED(hr)) {
        ts_set_error(n, "AppNotificationManager remove failed", hr);
        return;
    }
    /* Fire and forget: the removal is already queued, and the only thing the
     * IAsyncAction would tell us is that a notification we wanted gone was
     * already gone. Released rather than awaited so no caller thread blocks on
     * the notification platform. */
    if (operation) operation->lpVtbl->Release(operation);
}

void ts_winnotify_withdraw_group(ts_winnotify *n, const char *group) {
    HSTRING group_string;
    IUnknown *operation = NULL;
    HRESULT hr;

    if (!n || !n->manager || !group) return;
    ts_ensure_apartment();
    group_string = ts_hstring(group);
    if (!group_string) return;
    hr = n->manager->lpVtbl->RemoveByGroupAsync(n->manager, group_string, &operation);
    WindowsDeleteString(group_string);
    if (FAILED(hr)) {
        ts_set_error(n, "AppNotificationManager remove-group failed", hr);
        return;
    }
    if (operation) operation->lpVtbl->Release(operation);
}

const char *ts_winnotify_last_error(ts_winnotify *n) {
    if (!n || !n->has_error) return NULL;
    return n->error;
}

const char *ts_winnotify_open_error(void) { return g_open_error[0] ? g_open_error : NULL; }

int32_t ts_winnotify_activation_argument(void *event_args, char *out, int32_t capacity) {
    TSActivatedEventArgs *args = NULL;
    IUnknown *unknown = (IUnknown *)event_args;
    HSTRING argument = NULL;
    const wchar_t *wide;
    UINT32 wide_len = 0;
    int written;
    HRESULT hr;

    if (!event_args || !out || capacity <= 0) return 0;
    out[0] = '\0';

    hr = unknown->lpVtbl->QueryInterface(unknown, &TS_IID_AppNotificationActivatedEventArgs,
                                         (void **)&args);
    if (FAILED(hr) || !args) {
        /* Not a toast activation. Every other ExtendedActivationKind lands
         * here, which is why this is a 0 rather than an error: the host asks
         * this question of activations it did not post. */
        return 0;
    }

    hr = args->lpVtbl->get_Argument(args, &argument);
    if (FAILED(hr)) {
        args->lpVtbl->Release(args);
        return 0;
    }
    /* An empty argument comes back as a NULL HSTRING, not as a zero-length
     * one — the usual WinRT trap, and here it would be a valid-looking empty
     * answer rather than the "nothing was said" it really is. */
    wide = WindowsGetStringRawBuffer(argument, &wide_len);
    written = wide ? WideCharToMultiByte(CP_UTF8, 0, wide, (int)wide_len, out, capacity - 1, NULL,
                                         NULL)
                   : 0;
    if (written > 0) out[written] = '\0';
    WindowsDeleteString(argument);
    args->lpVtbl->Release(args);
    return written > 0 ? 1 : 0;
}

int32_t ts_winnotify_is_supported(void) { return 1; }

#else

/* Off Windows every entry point fails, so the Swift wrapper reports
 * "nowhere to post" and Linux CI can still typecheck everything above it —
 * the same shape as CWinHotkey's and CSendInput's non-Windows halves.
 *
 * Deliberately NOT a second implementation: a stub that pretended to post
 * would let the wrapper's tests pass against behaviour Windows does not have,
 * which is the failure mode a stub exists to avoid. */

ts_winnotify *ts_winnotify_open(const char *display_name) {
    (void)display_name;
    return NULL;
}

void ts_winnotify_close(ts_winnotify *n) { (void)n; }

int32_t ts_winnotify_setting(ts_winnotify *n) {
    (void)n;
    return TS_WINNOTIFY_SETTING_UNKNOWN;
}

int32_t ts_winnotify_supports_urgent(void) { return 0; }

uint32_t ts_winnotify_post(ts_winnotify *n, const char *payload_xml, const char *tag,
                           const char *group, int32_t high_priority) {
    (void)n;
    (void)payload_xml;
    (void)tag;
    (void)group;
    (void)high_priority;
    return 0;
}

void ts_winnotify_withdraw(ts_winnotify *n, const char *tag, const char *group) {
    (void)n;
    (void)tag;
    (void)group;
}

void ts_winnotify_withdraw_group(ts_winnotify *n, const char *group) {
    (void)n;
    (void)group;
}

const char *ts_winnotify_last_error(ts_winnotify *n) {
    (void)n;
    return NULL;
}

const char *ts_winnotify_open_error(void) { return "not Windows"; }

int32_t ts_winnotify_activation_argument(void *event_args, char *out, int32_t capacity) {
    (void)event_args;
    (void)out;
    (void)capacity;
    return 0;
}

int32_t ts_winnotify_is_supported(void) { return 0; }

#endif
