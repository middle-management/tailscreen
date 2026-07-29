#include "include/ts_overlay.h"

#include <stddef.h>

#if defined(_WIN32)

#include <windows.h>

/*
 * No MSVC STL headers, for the reason WASAPIKit documents: its <cstdlib>
 * hard-asserts a compiler version this toolchain's clang does not satisfy
 * (`error STL1000`). Win32 supplies allocation and copying.
 */

/* Posted to the overlay's own thread. Thread messages (no hwnd) rather than
 * window messages, so the pump handles them directly and there is no
 * possibility of one arriving while the window is being destroyed. */
#define TS_OVERLAY_MSG_PRESENT (WM_APP + 1)
#define TS_OVERLAY_MSG_HIDE (WM_APP + 2)
#define TS_OVERLAY_MSG_QUIT (WM_APP + 3)

struct ts_overlay {
    HWND window;
    HDC memoryDC;
    HBITMAP bitmap;
    void *pixels;
    int32_t x;
    int32_t y;
    int32_t width;
    int32_t height;
    int32_t visible;
    /* The thread that owns `window` and runs the pump. */
    HANDLE thread;
    DWORD threadID;
    /* Signalled once the thread has built (or failed to build) the window AND
     * has a message queue — posting before either is a silent no-op. */
    HANDLE ready;
    /* Set by the thread before signalling `ready`; read by the creator to
     * decide whether it got a working overlay. */
    int32_t created;
    /* Guards `pixels` between a caller copying the next frame in and the pump
     * compositing the current one out. */
    CRITICAL_SECTION pixelLock;
};

static const wchar_t *kClassName = L"TailscreenAnnotationOverlay";

static LRESULT CALLBACK ts_overlay_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    /* WM_NCHITTEST returning HTTRANSPARENT is belt-and-braces alongside
     * WS_EX_TRANSPARENT: this window must never take a click. It sits on top
     * of the sharer's own desktop, and swallowing input would make their
     * machine feel broken while someone else is drawing on it. */
    if (message == WM_NCHITTEST) {
        return HTTRANSPARENT;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

static void ts_overlay_register_class(void) {
    static LONG registered = 0;
    if (InterlockedCompareExchange(&registered, 1, 0) != 0) {
        return;
    }
    WNDCLASSEXW wc;
    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = ts_overlay_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = kClassName;
    RegisterClassExW(&wc);
}

/* Build the window and its backing bitmap. Runs on the overlay's thread, which
 * is the only thread allowed to own the window. */
static int32_t ts_overlay_build(ts_overlay *overlay) {
    ts_overlay_register_class();

    /* LAYERED gives per-pixel alpha; TRANSPARENT and NOACTIVATE make it
     * click-through and stop it stealing focus; TOOLWINDOW keeps it out of
     * Alt-Tab and the taskbar, where an invisible entry would be baffling. */
    overlay->window = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
        kClassName, L"", WS_POPUP, overlay->x, overlay->y, overlay->width, overlay->height, NULL,
        NULL, GetModuleHandleW(NULL), NULL);
    if (overlay->window == NULL) {
        return 0;
    }

    /* Keep the overlay OUT of what we capture.
     *
     * Viewers receive annotations over the relay channel and draw them
     * themselves, so capturing the overlay too would show every stroke twice
     * on their screen — once immediately, once again a video round-trip later,
     * slightly stale. This is also the one place `WDA_EXCLUDEFROMCAPTURE` is
     * available to us: it is set by a window's OWNER, which is why it cannot
     * implement Cloaked Apps for someone else's window, and why it works
     * perfectly here.
     *
     * Best-effort: it needs Windows 10 2004 or newer. On older builds the
     * overlay is captured, viewers see a doubled stroke, and that is a
     * cosmetic problem rather than a broken share — not worth refusing to
     * annotate at all. */
    SetWindowDisplayAffinity(overlay->window, WDA_EXCLUDEFROMCAPTURE);

    HDC screen = GetDC(NULL);
    if (screen == NULL) {
        return 0;
    }
    overlay->memoryDC = CreateCompatibleDC(screen);

    BITMAPINFO info;
    ZeroMemory(&info, sizeof(info));
    info.bmiHeader.biSize = sizeof(info.bmiHeader);
    info.bmiHeader.biWidth = overlay->width;
    /* NEGATIVE height: top-down rows, matching every other buffer in this
     * codebase. A bottom-up DIB would silently render the annotations
     * mirrored vertically. */
    info.bmiHeader.biHeight = -overlay->height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    overlay->bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &overlay->pixels, NULL, 0);
    ReleaseDC(NULL, screen);

    if (overlay->memoryDC == NULL || overlay->bitmap == NULL || overlay->pixels == NULL) {
        return 0;
    }
    SelectObject(overlay->memoryDC, overlay->bitmap);
    return 1;
}

/* Composite the current bitmap and show the window. Runs on the pump thread. */
static void ts_overlay_present(ts_overlay *overlay) {
    POINT source = {0, 0};
    POINT position = {overlay->x, overlay->y};
    SIZE size = {overlay->width, overlay->height};
    BLENDFUNCTION blend;
    blend.BlendOp = AC_SRC_OVER;
    blend.BlendFlags = 0;
    blend.SourceConstantAlpha = 255;
    /* AC_SRC_ALPHA says the bitmap carries per-pixel alpha and is
     * PREMULTIPLIED — which is why AnnotationRasterizer premultiplies, and
     * why its tests assert that it does. */
    blend.AlphaFormat = AC_SRC_ALPHA;

    HDC screen = GetDC(NULL);
    /* Held across the composite so a caller cannot overwrite the bitmap
     * mid-blit and tear a stroke in half. */
    EnterCriticalSection(&overlay->pixelLock);
    UpdateLayeredWindow(overlay->window, screen, &position, &size, overlay->memoryDC, &source, 0,
                        &blend, ULW_ALPHA);
    LeaveCriticalSection(&overlay->pixelLock);
    if (screen != NULL) {
        ReleaseDC(NULL, screen);
    }

    if (!overlay->visible) {
        overlay->visible = 1;
        /* SW_SHOWNOACTIVATE, not SW_SHOW: showing the overlay must never take
         * focus away from whatever the sharer is doing. */
        ShowWindow(overlay->window, SW_SHOWNOACTIVATE);
    }
}

static DWORD WINAPI ts_overlay_thread(LPVOID parameter) {
    ts_overlay *overlay = (ts_overlay *)parameter;
    MSG msg;

    overlay->created = ts_overlay_build(overlay);

    /* Force the message queue into existence before anyone can post to it.
     * PostThreadMessage fails — silently, from the poster's point of view, and
     * the overlay would simply never draw — until the thread has called a
     * message function at least once. */
    PeekMessageW(&msg, NULL, WM_USER, WM_USER, PM_NOREMOVE);
    SetEvent(overlay->ready);
    if (!overlay->created) {
        return 0;
    }

    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (msg.hwnd == NULL) {
            if (msg.message == TS_OVERLAY_MSG_PRESENT) {
                ts_overlay_present(overlay);
                continue;
            }
            if (msg.message == TS_OVERLAY_MSG_HIDE) {
                if (overlay->visible) {
                    overlay->visible = 0;
                    ShowWindow(overlay->window, SW_HIDE);
                }
                continue;
            }
            if (msg.message == TS_OVERLAY_MSG_QUIT) {
                break;
            }
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    /* Destroyed here because a window may only be destroyed by the thread that
     * created it — the same rule that made owning this thread necessary. */
    if (overlay->window != NULL) {
        DestroyWindow(overlay->window);
        overlay->window = NULL;
    }
    if (overlay->bitmap != NULL) {
        DeleteObject(overlay->bitmap);
        overlay->bitmap = NULL;
    }
    if (overlay->memoryDC != NULL) {
        DeleteDC(overlay->memoryDC);
        overlay->memoryDC = NULL;
    }
    return 0;
}

ts_overlay *ts_overlay_create(int32_t x, int32_t y, int32_t width, int32_t height) {
    if (width <= 0 || height <= 0) {
        return NULL;
    }

    ts_overlay *overlay =
        (ts_overlay *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(ts_overlay));
    if (overlay == NULL) {
        return NULL;
    }
    overlay->x = x;
    overlay->y = y;
    overlay->width = width;
    overlay->height = height;
    InitializeCriticalSection(&overlay->pixelLock);

    overlay->ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (overlay->ready == NULL) {
        DeleteCriticalSection(&overlay->pixelLock);
        HeapFree(GetProcessHeap(), 0, overlay);
        return NULL;
    }

    overlay->thread = CreateThread(NULL, 0, ts_overlay_thread, overlay, 0, &overlay->threadID);
    if (overlay->thread == NULL) {
        CloseHandle(overlay->ready);
        DeleteCriticalSection(&overlay->pixelLock);
        HeapFree(GetProcessHeap(), 0, overlay);
        return NULL;
    }

    /* Bounded rather than INFINITE: this is called while a share is starting,
     * and a hang here would look like a share that never begins. A timeout
     * means no overlay, which the caller already handles. */
    WaitForSingleObject(overlay->ready, 5000);
    if (!overlay->created) {
        ts_overlay_destroy(overlay);
        return NULL;
    }
    return overlay;
}

int32_t ts_overlay_update(ts_overlay *overlay, const uint8_t *bgra, int32_t width,
                          int32_t height) {
    if (overlay == NULL || bgra == NULL || overlay->pixels == NULL) {
        return 0;
    }
    /* Geometry must match exactly: a resized display needs a new overlay, not
     * a stretched one, and silently scaling would put strokes in the wrong
     * place — the precise failure the whole coordinate-mapping effort exists
     * to avoid. */
    if (width != overlay->width || height != overlay->height) {
        return 0;
    }

    EnterCriticalSection(&overlay->pixelLock);
    CopyMemory(overlay->pixels, bgra, (SIZE_T)width * (SIZE_T)height * 4);
    LeaveCriticalSection(&overlay->pixelLock);

    return PostThreadMessageW(overlay->threadID, TS_OVERLAY_MSG_PRESENT, 0, 0) ? 1 : 0;
}

void ts_overlay_hide(ts_overlay *overlay) {
    if (overlay == NULL) {
        return;
    }
    PostThreadMessageW(overlay->threadID, TS_OVERLAY_MSG_HIDE, 0, 0);
}

void ts_overlay_destroy(ts_overlay *overlay) {
    if (overlay == NULL) {
        return;
    }
    if (overlay->thread != NULL) {
        PostThreadMessageW(overlay->threadID, TS_OVERLAY_MSG_QUIT, 0, 0);
        /* Bounded for the same reason as creation: this runs when a share
         * ends, and a stuck pump must not wedge that. The window then outlives
         * the wait, but the process is the one that owns it and a share ending
         * is not a moment to block the user. */
        WaitForSingleObject(overlay->thread, 2000);
        CloseHandle(overlay->thread);
    }
    if (overlay->ready != NULL) {
        CloseHandle(overlay->ready);
    }
    DeleteCriticalSection(&overlay->pixelLock);
    HeapFree(GetProcessHeap(), 0, overlay);
}

#else

/*
 * Off Windows the overlay does not exist, so creation fails and everything
 * else is a no-op — which lets the Swift wrapper and its callers compile and
 * be typechecked on Linux CI. Same shape as WGCCaptureKit's and SendInputKit's
 * stubs.
 */

ts_overlay *ts_overlay_create(int32_t x, int32_t y, int32_t width, int32_t height) {
    (void)x;
    (void)y;
    (void)width;
    (void)height;
    return NULL;
}

int32_t ts_overlay_update(ts_overlay *overlay, const uint8_t *bgra, int32_t width,
                          int32_t height) {
    (void)overlay;
    (void)bgra;
    (void)width;
    (void)height;
    return 0;
}

void ts_overlay_hide(ts_overlay *overlay) { (void)overlay; }

void ts_overlay_destroy(ts_overlay *overlay) { (void)overlay; }

#endif
