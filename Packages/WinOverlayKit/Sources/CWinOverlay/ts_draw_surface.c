#include "include/ts_draw_surface.h"

#include <stddef.h>

#if defined(_WIN32)

#include <windows.h>

/* No MSVC STL headers — see ts_overlay.c for why. */

#define TS_DRAW_MSG_QUIT (WM_APP + 11)

/* How opaque the wash is, 0…255.
 *
 * A judgement call between two failures. Too faint and an armed surface is
 * indistinguishable from a desktop that has stopped responding to the mouse;
 * too heavy and the sharer cannot see what they are drawing on. ~47 % reads as
 * a modal scrim, which is exactly what this is, and leaves the caption legible.
 *
 * Uniform alpha via SetLayeredWindowAttributes rather than per-pixel alpha via
 * UpdateLayeredWindow, and that is not a style preference: **hit testing of a
 * layered window follows its alpha**, so a per-pixel surface would let clicks
 * through everywhere it was transparent — i.e. everywhere it needed to catch
 * them. A window that must swallow the pointer cannot be transparent anywhere. */
#define TS_DRAW_ALPHA 120

#define TS_DRAW_BORDER 4
#define TS_DRAW_CAPTION_HEIGHT 44

struct ts_draw_surface {
    HWND window;
    int32_t x;
    int32_t y;
    int32_t width;
    int32_t height;
    void *context;
    ts_draw_pointer_cb onPointer;
    ts_draw_release_cb onRelease;
    HANDLE thread;
    DWORD threadID;
    HANDLE ready;
    /* TS_DRAW_OK / _NO_SURFACE / _NO_KEYBOARD, set on the pump thread before
     * `ready` is signalled. */
    int32_t status;
    /* A button is held, so moves are stroke points rather than hovering. */
    LONG drawing;
    /* Last pointer position, so a capture lost mid-drag can still end the
     * stroke somewhere sensible — WM_CAPTURECHANGED carries no coordinates. */
    LONG lastX;
    LONG lastY;
    /* Suppresses onRelease. Set while the window is being built (the focus
     * changes that provokes are not the sharer alt-tabbing away) and again from
     * the moment teardown begins (WM_KILLFOCUS arrives during DestroyWindow,
     * and a release callback fired from inside teardown is a re-entrant
     * destroy). */
    LONG quiet;
};

static const wchar_t *kDrawClassName = L"TailscreenSharerDrawSurface";
static const wchar_t *kCaption = L"Drawing on your screen  —  press Esc to stop";

static void ts_draw_emit(ts_draw_surface *surface, int32_t phase, LPARAM lparam) {
    /* The signed cast is the point. WM_MOUSEMOVE packs coordinates into a
     * SIGNED 16-bit pair, and a drag that leaves the window reports negative
     * ones. Read with LOWORD they arrive as ~65535 and the stroke teleports to
     * the opposite edge — a bug that only ever shows up when somebody drags off
     * the screen, which is often. */
    int32_t x = (int32_t)(short)LOWORD(lparam);
    int32_t y = (int32_t)(short)HIWORD(lparam);
    surface->lastX = x;
    surface->lastY = y;
    if (surface->onPointer != NULL) {
        surface->onPointer(surface->context, phase, x, y);
    }
}

static void ts_draw_release(ts_draw_surface *surface) {
    if (InterlockedCompareExchange(&surface->quiet, 0, 0) != 0) {
        return;
    }
    /* End any stroke in flight first. A drag interrupted by Alt-Tab must not
     * leave a stroke that never finished — the same reason the input injector
     * synthesizes a button-up when a grant is revoked mid-drag. */
    if (InterlockedExchange(&surface->drawing, 0) != 0 && surface->onPointer != NULL) {
        surface->onPointer(surface->context, 2, (int32_t)surface->lastX, (int32_t)surface->lastY);
    }
    if (surface->onRelease != NULL) {
        surface->onRelease(surface->context);
    }
}

static void ts_draw_paint(ts_draw_surface *surface, HWND hwnd) {
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(hwnd, &ps);
    if (dc == NULL) {
        return;
    }

    RECT full;
    full.left = 0;
    full.top = 0;
    full.right = surface->width;
    full.bottom = surface->height;

    HBRUSH wash = CreateSolidBrush(RGB(8, 10, 14));
    if (wash != NULL) {
        FillRect(dc, &full, wash);
        DeleteObject(wash);
    }

    /* An accent frame, so the boundary of what is being drawn on is visible
     * even where the wash blends into dark content underneath. */
    HBRUSH accent = CreateSolidBrush(RGB(255, 208, 64));
    if (accent != NULL) {
        RECT band;
        band = full;
        band.bottom = TS_DRAW_BORDER;
        FillRect(dc, &band, accent);
        band = full;
        band.top = full.bottom - TS_DRAW_BORDER;
        FillRect(dc, &band, accent);
        band = full;
        band.right = TS_DRAW_BORDER;
        FillRect(dc, &band, accent);
        band = full;
        band.left = full.right - TS_DRAW_BORDER;
        FillRect(dc, &band, accent);

        /* The caption strip. Centred at the top, in the same accent, because
         * this sentence is the only way out of the mode and the hub window that
         * would otherwise carry it is now behind this window. */
        RECT caption;
        caption.left = full.right / 2 - 300;
        caption.right = full.right / 2 + 300;
        caption.top = TS_DRAW_BORDER;
        caption.bottom = TS_DRAW_BORDER + TS_DRAW_CAPTION_HEIGHT;
        if (caption.left < TS_DRAW_BORDER) {
            caption.left = TS_DRAW_BORDER;
        }
        if (caption.right > full.right - TS_DRAW_BORDER) {
            caption.right = full.right - TS_DRAW_BORDER;
        }
        FillRect(dc, &caption, accent);

        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(20, 16, 0));
        HGDIOBJ font = GetStockObject(DEFAULT_GUI_FONT);
        HGDIOBJ previous = SelectObject(dc, font);
        DrawTextW(dc, kCaption, -1, &caption, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        SelectObject(dc, previous);
        DeleteObject(accent);
    }

    EndPaint(hwnd, &ps);
}

static LRESULT CALLBACK ts_draw_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    ts_draw_surface *surface = (ts_draw_surface *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (surface == NULL) {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }

    switch (message) {
    case WM_LBUTTONDOWN:
        /* Capture, so the rest of the stroke arrives even once the pointer
         * leaves this window — which it will, at the edges of the region, which
         * is exactly where people draw arrows. */
        SetCapture(hwnd);
        InterlockedExchange(&surface->drawing, 1);
        ts_draw_emit(surface, 0, lparam);
        return 0;
    case WM_MOUSEMOVE:
        if (InterlockedCompareExchange(&surface->drawing, 0, 0) != 0) {
            ts_draw_emit(surface, 1, lparam);
        }
        return 0;
    case WM_LBUTTONUP:
        if (InterlockedExchange(&surface->drawing, 0) != 0) {
            ts_draw_emit(surface, 2, lparam);
        }
        ReleaseCapture();
        return 0;
    case WM_CAPTURECHANGED:
        /* Capture taken away mid-drag. Close the stroke at the last point
         * rather than leaving it open forever — this message carries no
         * coordinates, which is why the last one is kept. */
        if (InterlockedExchange(&surface->drawing, 0) != 0 && surface->onPointer != NULL) {
            surface->onPointer(surface->context, 2, (int32_t)surface->lastX,
                               (int32_t)surface->lastY);
        }
        return 0;
    case WM_KEYDOWN:
        if (wparam == VK_ESCAPE) {
            ts_draw_release(surface);
            return 0;
        }
        break;
    case WM_KILLFOCUS:
        /* The Windows-specific hazard. This is an ordinary top-level window, so
         * Alt-Tab, the Windows key and UAC can all take the keyboard — leaving a
         * window that still swallows every click and an Escape key that no
         * longer reaches it. Losing focus therefore ENDS drawing rather than
         * being noted. */
        ts_draw_release(surface);
        return 0;
    case WM_ERASEBKGND:
        /* WM_PAINT covers every pixel; erasing first only flickers. */
        return 1;
    case WM_PAINT:
        ts_draw_paint(surface, hwnd);
        return 0;
    case WM_CLOSE:
        ts_draw_release(surface);
        return 0;
    default:
        break;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

static void ts_draw_register_class(void) {
    static LONG registered = 0;
    if (InterlockedCompareExchange(&registered, 1, 0) != 0) {
        return;
    }
    WNDCLASSEXW wc;
    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = ts_draw_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = kDrawClassName;
    /* An arrow, deliberately, not a crosshair: the sharer is drawing over their
     * own desktop and a cursor that stops looking like a cursor reads as the
     * machine having gone strange. */
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    RegisterClassExW(&wc);
}

/* Build, show and focus. Runs on the surface's own thread — the only one
 * allowed to own the window. Returns a TS_DRAW_* status. */
static int32_t ts_draw_build(ts_draw_surface *surface) {
    ts_draw_register_class();

    /* No WS_EX_TRANSPARENT and no WS_EX_NOACTIVATE — the two the annotation
     * overlay depends on — because this window's entire job is the opposite:
     * take the clicks, take the keyboard. TOOLWINDOW keeps it out of Alt-Tab
     * and the taskbar, where an entry for a modal scrim would be noise. */
    surface->window = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
                                      kDrawClassName, L"", WS_POPUP, surface->x, surface->y,
                                      surface->width, surface->height, NULL, NULL,
                                      GetModuleHandleW(NULL), NULL);
    if (surface->window == NULL) {
        return TS_DRAW_NO_SURFACE;
    }
    SetWindowLongPtrW(surface->window, GWLP_USERDATA, (LONG_PTR)surface);
    SetLayeredWindowAttributes(surface->window, 0, TS_DRAW_ALPHA, LWA_ALPHA);
    /* Same reasoning as the annotation overlay's: viewers must not receive a
     * dimmed picture of the sharer's screen. Best-effort (Windows 10 2004+);
     * on older builds the wash is captured, which is cosmetic. */
    SetWindowDisplayAffinity(surface->window, WDA_EXCLUDEFROMCAPTURE);

    ShowWindow(surface->window, SW_SHOW);
    SetForegroundWindow(surface->window);
    SetFocus(surface->window);

    /* Let the activation messages this just queued actually run, so the checks
     * below read the settled state rather than the one from a moment ago. */
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    /* **Verify, and refuse if it did not take.** SetForegroundWindow is
     * advisory: the system declines it for a process that is not already in the
     * foreground and flashes a taskbar button instead, reporting nothing useful.
     * A surface that swallows the pointer without the keyboard has no way out,
     * so an unverified arm is worse than no drawing at all. */
    if (GetForegroundWindow() != surface->window || GetFocus() != surface->window) {
        return TS_DRAW_NO_KEYBOARD;
    }
    return TS_DRAW_OK;
}

static DWORD WINAPI ts_draw_thread(LPVOID parameter) {
    ts_draw_surface *surface = (ts_draw_surface *)parameter;
    MSG msg;

    surface->status = ts_draw_build(surface);

    /* Force the queue into existence before anyone can post to it, exactly as
     * ts_overlay does — PostThreadMessage silently fails until the thread has
     * called a message function at least once. */
    PeekMessageW(&msg, NULL, WM_USER, WM_USER, PM_NOREMOVE);

    if (surface->status != TS_DRAW_OK) {
        /* Take the failed window down HERE, on its own thread, before telling
         * the creator anything. A half-built surface that outlived its own
         * refusal is the trap wearing a "this did not work" label. */
        if (surface->window != NULL) {
            DestroyWindow(surface->window);
            surface->window = NULL;
        }
        SetEvent(surface->ready);
        return 0;
    }

    /* Live from here on: releases are now the sharer's, not the build's. */
    InterlockedExchange(&surface->quiet, 0);
    SetEvent(surface->ready);

    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (msg.hwnd == NULL && msg.message == TS_DRAW_MSG_QUIT) {
            break;
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    if (surface->window != NULL) {
        DestroyWindow(surface->window);
        surface->window = NULL;
    }
    return 0;
}

ts_draw_surface *ts_draw_surface_create(int32_t x, int32_t y, int32_t width, int32_t height,
                                        void *context, ts_draw_pointer_cb on_pointer,
                                        ts_draw_release_cb on_release, int32_t *out_status) {
    if (out_status != NULL) {
        *out_status = TS_DRAW_NO_SURFACE;
    }
    if (width <= 0 || height <= 0) {
        return NULL;
    }

    ts_draw_surface *surface =
        (ts_draw_surface *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(ts_draw_surface));
    if (surface == NULL) {
        return NULL;
    }
    surface->x = x;
    surface->y = y;
    surface->width = width;
    surface->height = height;
    surface->context = context;
    surface->onPointer = on_pointer;
    surface->onRelease = on_release;
    /* Quiet until the build has settled: the focus churn of showing a window is
     * not the sharer asking to stop. */
    surface->quiet = 1;

    surface->ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (surface->ready == NULL) {
        HeapFree(GetProcessHeap(), 0, surface);
        return NULL;
    }

    surface->thread = CreateThread(NULL, 0, ts_draw_thread, surface, 0, &surface->threadID);
    if (surface->thread == NULL) {
        CloseHandle(surface->ready);
        HeapFree(GetProcessHeap(), 0, surface);
        return NULL;
    }

    /* Bounded, like the overlay's: this runs on a click, and a hang here would
     * be a toolbar button that never comes back. A timeout reads as a refusal,
     * which the caller already handles. */
    WaitForSingleObject(surface->ready, 5000);
    int32_t status = surface->status;
    if (status != TS_DRAW_OK) {
        if (out_status != NULL) {
            *out_status = (status == TS_DRAW_NO_KEYBOARD) ? TS_DRAW_NO_KEYBOARD
                                                          : TS_DRAW_NO_SURFACE;
        }
        ts_draw_surface_destroy(surface);
        return NULL;
    }
    if (out_status != NULL) {
        *out_status = TS_DRAW_OK;
    }
    return surface;
}

void ts_draw_surface_destroy(ts_draw_surface *surface) {
    if (surface == NULL) {
        return;
    }
    /* Silence callbacks BEFORE anything else. DestroyWindow delivers
     * WM_KILLFOCUS, and a release callback fired from inside teardown would
     * re-enter this function from the thread it is waiting on. */
    InterlockedExchange(&surface->quiet, 1);
    if (surface->thread != NULL) {
        PostThreadMessageW(surface->threadID, TS_DRAW_MSG_QUIT, 0, 0);
        /* Longer than the overlay's 2 s, and deliberately so: this is the
         * direction where giving up early is dangerous. The overlay outliving
         * its wait is an invisible window; THIS window outliving its wait is a
         * desktop that swallows clicks. The pump does nothing but dispatch, so
         * exceeding this would mean Windows itself is wedged — and even then the
         * window dies with the thread. */
        WaitForSingleObject(surface->thread, 10000);
        CloseHandle(surface->thread);
    }
    if (surface->ready != NULL) {
        CloseHandle(surface->ready);
    }
    HeapFree(GetProcessHeap(), 0, surface);
}

#else

/*
 * Off Windows there is no surface, so creation fails with TS_DRAW_NO_SURFACE
 * and teardown is a no-op — which is what lets the Swift wrapper, the share
 * session and the app above it all be typechecked on Linux CI. Same shape as
 * ts_overlay.c's stub.
 */

ts_draw_surface *ts_draw_surface_create(int32_t x, int32_t y, int32_t width, int32_t height,
                                        void *context, ts_draw_pointer_cb on_pointer,
                                        ts_draw_release_cb on_release, int32_t *out_status) {
    (void)x;
    (void)y;
    (void)width;
    (void)height;
    (void)context;
    (void)on_pointer;
    (void)on_release;
    if (out_status != NULL) {
        *out_status = TS_DRAW_NO_SURFACE;
    }
    return NULL;
}

void ts_draw_surface_destroy(ts_draw_surface *surface) { (void)surface; }

#endif
