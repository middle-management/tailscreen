#include "include/ts_overlay.h"

#include <stddef.h>

#if defined(_WIN32)

#include <windows.h>

/*
 * No MSVC STL headers, for the reason WASAPIKit documents: its <cstdlib>
 * hard-asserts a compiler version this toolchain's clang does not satisfy
 * (`error STL1000`). Win32 supplies allocation and copying.
 */

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

ts_overlay *ts_overlay_create(int32_t x, int32_t y, int32_t width, int32_t height) {
    if (width <= 0 || height <= 0) {
        return NULL;
    }
    ts_overlay_register_class();

    ts_overlay *overlay =
        (ts_overlay *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(ts_overlay));
    if (overlay == NULL) {
        return NULL;
    }
    overlay->x = x;
    overlay->y = y;
    overlay->width = width;
    overlay->height = height;

    /* LAYERED gives per-pixel alpha; TRANSPARENT and NOACTIVATE make it
     * click-through and stop it stealing focus; TOOLWINDOW keeps it out of
     * Alt-Tab and the taskbar, where an invisible entry would be baffling. */
    overlay->window = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
        kClassName, L"", WS_POPUP, x, y, width, height, NULL, NULL, GetModuleHandleW(NULL),
        NULL);
    if (overlay->window == NULL) {
        HeapFree(GetProcessHeap(), 0, overlay);
        return NULL;
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
        DestroyWindow(overlay->window);
        HeapFree(GetProcessHeap(), 0, overlay);
        return NULL;
    }
    overlay->memoryDC = CreateCompatibleDC(screen);

    BITMAPINFO info;
    ZeroMemory(&info, sizeof(info));
    info.bmiHeader.biSize = sizeof(info.bmiHeader);
    info.bmiHeader.biWidth = width;
    /* NEGATIVE height: top-down rows, matching every other buffer in this
     * codebase. A bottom-up DIB would silently render the annotations
     * mirrored vertically. */
    info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    overlay->bitmap =
        CreateDIBSection(screen, &info, DIB_RGB_COLORS, &overlay->pixels, NULL, 0);
    ReleaseDC(NULL, screen);

    if (overlay->memoryDC == NULL || overlay->bitmap == NULL || overlay->pixels == NULL) {
        ts_overlay_destroy(overlay);
        return NULL;
    }
    SelectObject(overlay->memoryDC, overlay->bitmap);
    return overlay;
}

int32_t ts_overlay_update(ts_overlay *overlay, const uint8_t *bgra, int32_t width,
                          int32_t height) {
    if (overlay == NULL || bgra == NULL) {
        return 0;
    }
    /* Geometry must match exactly: a resized display needs a new overlay, not
     * a stretched one, and silently scaling would put strokes in the wrong
     * place — the precise failure the whole coordinate-mapping effort exists
     * to avoid. */
    if (width != overlay->width || height != overlay->height) {
        return 0;
    }
    CopyMemory(overlay->pixels, bgra, (SIZE_T)width * (SIZE_T)height * 4);

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
    BOOL ok = UpdateLayeredWindow(
        overlay->window, screen, &position, &size, overlay->memoryDC, &source, 0, &blend,
        ULW_ALPHA);
    if (screen != NULL) {
        ReleaseDC(NULL, screen);
    }
    return ok ? 1 : 0;
}

void ts_overlay_set_visible(ts_overlay *overlay, int32_t visible) {
    if (overlay == NULL || overlay->visible == visible) {
        return;
    }
    overlay->visible = visible;
    /* SW_SHOWNOACTIVATE, not SW_SHOW: showing the overlay must never take
     * focus away from whatever the sharer is doing. */
    ShowWindow(overlay->window, visible ? SW_SHOWNOACTIVATE : SW_HIDE);
}

void ts_overlay_destroy(ts_overlay *overlay) {
    if (overlay == NULL) {
        return;
    }
    if (overlay->bitmap != NULL) {
        DeleteObject(overlay->bitmap);
    }
    if (overlay->memoryDC != NULL) {
        DeleteDC(overlay->memoryDC);
    }
    if (overlay->window != NULL) {
        DestroyWindow(overlay->window);
    }
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

void ts_overlay_set_visible(ts_overlay *overlay, int32_t visible) {
    (void)overlay;
    (void)visible;
}

void ts_overlay_destroy(ts_overlay *overlay) { (void)overlay; }

#endif
