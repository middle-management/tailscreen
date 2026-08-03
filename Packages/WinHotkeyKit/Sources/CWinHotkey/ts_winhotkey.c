#include "include/ts_winhotkey.h"

/* For NULL. A compiler-provided header, not part of MSVC's STL — see the note
 * in CSendInput about why no STL header may appear in a file MSVC compiles. */
#include <stddef.h>

#if defined(_WIN32)

#include <windows.h>

/* One id, because one hotkey per handle. `RegisterHotKey`'s id space is
 * per-thread and each handle owns its own thread, so there is nothing to
 * collide with — the macOS shim needs distinct ids for the opposite reason,
 * that every hotkey there shares one application event target. */
#define TS_HOTKEY_ID 1

typedef struct {
    HANDLE thread;
    DWORD thread_id;
    /* Signalled once the thread has created its queue and attempted the
     * registration, so `create` can report a refusal instead of returning a
     * handle for a hotkey that was never taken. */
    HANDLE ready;
    LONG registered;
    volatile LONG activations;
    UINT modifiers;
    UINT virtual_key;
} TSWinHotkey;

static DWORD WINAPI ts_hotkey_pump(LPVOID parameter) {
    TSWinHotkey *h = (TSWinHotkey *)parameter;
    MSG msg;

    /* Force the message queue into existence before anything can post to it.
     * A thread has no queue until it first asks for a message, and
     * PostThreadMessage to a thread without one is silently lost. */
    PeekMessageW(&msg, NULL, WM_USER, WM_USER, PM_NOREMOVE);

    if (RegisterHotKey(NULL, TS_HOTKEY_ID, h->modifiers, h->virtual_key)) {
        InterlockedExchange(&h->registered, 1);
    }
    SetEvent(h->ready);
    if (!InterlockedCompareExchange(&h->registered, 1, 1)) {
        return 0;
    }

    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (msg.message == WM_HOTKEY && msg.wParam == TS_HOTKEY_ID) {
            InterlockedIncrement(&h->activations);
        }
        /* No TranslateMessage/DispatchMessage: there is no window on this
         * thread, and WM_HOTKEY is a thread message with nowhere to dispatch
         * to. The loop exists solely to pull it off the queue. */
    }

    UnregisterHotKey(NULL, TS_HOTKEY_ID);
    return 0;
}

void *ts_winhotkey_create(uint32_t modifiers, uint32_t virtual_key) {
    TSWinHotkey *h = (TSWinHotkey *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY,
                                              sizeof(TSWinHotkey));
    if (!h) return NULL;
    h->modifiers = (UINT)modifiers;
    h->virtual_key = (UINT)virtual_key;
    h->ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!h->ready) {
        HeapFree(GetProcessHeap(), 0, h);
        return NULL;
    }

    h->thread = CreateThread(NULL, 0, ts_hotkey_pump, h, 0, &h->thread_id);
    if (!h->thread) {
        CloseHandle(h->ready);
        HeapFree(GetProcessHeap(), 0, h);
        return NULL;
    }

    /* Bounded, not infinite: a wait that never returns would hang the app's
     * startup on a thread that failed in a way nobody anticipated. */
    WaitForSingleObject(h->ready, 5000);
    if (!InterlockedCompareExchange(&h->registered, 1, 1)) {
        ts_winhotkey_destroy(h);
        return NULL;
    }
    return h;
}

void ts_winhotkey_destroy(void *handle) {
    TSWinHotkey *h = (TSWinHotkey *)handle;
    if (!h) return;
    if (h->thread) {
        /* WM_QUIT ends GetMessage, and the pump unregisters on its way out —
         * on the thread that registered, which is the only thread allowed to.
         */
        PostThreadMessageW(h->thread_id, WM_QUIT, 0, 0);
        WaitForSingleObject(h->thread, 5000);
        CloseHandle(h->thread);
    }
    if (h->ready) CloseHandle(h->ready);
    HeapFree(GetProcessHeap(), 0, h);
}

int32_t ts_winhotkey_take(void *handle) {
    TSWinHotkey *h = (TSWinHotkey *)handle;
    if (!h) return 0;
    return (int32_t)InterlockedExchange(&h->activations, 0);
}

int32_t ts_winhotkey_supported(void) { return 1; }

#else

/* Off Windows every entry point fails, so the Swift wrapper reports
 * `.unsupportedPlatform` and Linux CI can still typecheck everything above it.
 * Same shape as CSendInput's non-Windows half. */

void *ts_winhotkey_create(uint32_t modifiers, uint32_t virtual_key) {
    (void)modifiers;
    (void)virtual_key;
    return NULL;
}

void ts_winhotkey_destroy(void *handle) { (void)handle; }

int32_t ts_winhotkey_take(void *handle) {
    (void)handle;
    return 0;
}

int32_t ts_winhotkey_supported(void) { return 0; }

#endif
