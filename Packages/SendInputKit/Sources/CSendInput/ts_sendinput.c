#include "include/ts_sendinput.h"

/* For NULL. A compiler-provided header, not part of MSVC's STL — see the note
 * below about why no STL header may appear in this file. */
#include <stddef.h>

#if defined(_WIN32)

#include <windows.h>

/*
 * No <string.h>, <stdlib.h> or any other C++ standard header, deliberately.
 * WASAPIKit's shim hit `error STL1000: Unexpected compiler version, expected
 * Clang 20 or newer` from MSVC's STL, and the fix there was to use Win32
 * (`HeapAlloc`, `CopyMemory`) instead. <stdint.h> in the header is fine: it
 * comes from the UCRT, not the STL.
 */

static const int32_t kAbsoluteMax = 65535;

static int32_t ts_clamp_absolute(int32_t value) {
    if (value < 0) {
        return 0;
    }
    if (value > kAbsoluteMax) {
        return kAbsoluteMax;
    }
    return value;
}

static void ts_fill_move(INPUT *input, int32_t x, int32_t y) {
    ZeroMemory(input, sizeof(*input));
    input->type = INPUT_MOUSE;
    input->mi.dx = ts_clamp_absolute(x);
    input->mi.dy = ts_clamp_absolute(y);
    /* VIRTUALDESK is what makes the coordinates span every monitor rather
     * than only the primary one. Without it a multi-monitor sharer can be
     * driven on one screen and nowhere else. */
    input->mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
}

int32_t ts_input_mouse_move(int32_t absolute_x, int32_t absolute_y) {
    INPUT input;
    ts_fill_move(&input, absolute_x, absolute_y);
    return (int32_t)SendInput(1, &input, sizeof(INPUT));
}

int32_t ts_input_mouse_button(int32_t absolute_x, int32_t absolute_y, int32_t button,
                              int32_t down) {
    DWORD flags = 0;
    switch (button) {
    case 0:
        flags = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
        break;
    case 1:
        flags = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
        break;
    case 2:
        flags = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
        break;
    default:
        return 0;
    }

    /* Position and press in ONE SendInput call. The batch is delivered
     * atomically, so no other process's cursor motion can land between the
     * move and the click — which is otherwise a real way for a remote click
     * to arrive somewhere the viewer did not aim it. */
    INPUT inputs[2];
    ts_fill_move(&inputs[0], absolute_x, absolute_y);
    ZeroMemory(&inputs[1], sizeof(inputs[1]));
    inputs[1].type = INPUT_MOUSE;
    inputs[1].mi.dwFlags = flags;
    return (int32_t)SendInput(2, inputs, sizeof(INPUT));
}

int32_t ts_input_scroll(int32_t absolute_x, int32_t absolute_y, int32_t wheel_y,
                        int32_t wheel_x) {
    INPUT inputs[3];
    UINT count = 0;
    ts_fill_move(&inputs[count++], absolute_x, absolute_y);

    if (wheel_y != 0) {
        ZeroMemory(&inputs[count], sizeof(inputs[count]));
        inputs[count].type = INPUT_MOUSE;
        inputs[count].mi.dwFlags = MOUSEEVENTF_WHEEL;
        /* mouseData is a DWORD holding a SIGNED value; the cast preserves the
         * sign bits that a scroll-down needs. */
        inputs[count].mi.mouseData = (DWORD)wheel_y;
        count++;
    }
    if (wheel_x != 0) {
        ZeroMemory(&inputs[count], sizeof(inputs[count]));
        inputs[count].type = INPUT_MOUSE;
        inputs[count].mi.dwFlags = MOUSEEVENTF_HWHEEL;
        inputs[count].mi.mouseData = (DWORD)wheel_x;
        count++;
    }
    if (count == 1) {
        return 0;  /* Nothing but the move; the caller asked for no scroll. */
    }
    return (int32_t)SendInput(count, inputs, sizeof(INPUT));
}

int32_t ts_input_key(uint16_t virtual_key, int32_t extended, int32_t down) {
    INPUT input;
    ZeroMemory(&input, sizeof(input));
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = virtual_key;
    /* The scan code is left at zero and wVk is used directly: the receiving
     * app resolves the layout, which is what keeps keyboard handling on the
     * SHARER's machine as the protocol intends. */
    input.ki.dwFlags = 0;
    if (extended) {
        input.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
    }
    if (!down) {
        input.ki.dwFlags |= KEYEVENTF_KEYUP;
    }
    return (int32_t)SendInput(1, &input, sizeof(INPUT));
}

void ts_input_virtual_desktop(int32_t *out_x, int32_t *out_y, int32_t *out_width,
                              int32_t *out_height) {
    if (out_x != NULL) {
        *out_x = GetSystemMetrics(SM_XVIRTUALSCREEN);
    }
    if (out_y != NULL) {
        *out_y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    }
    if (out_width != NULL) {
        *out_width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    }
    if (out_height != NULL) {
        *out_height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    }
}

struct ts_monitor_sink {
    int32_t *rects;
    int32_t capacity;
    int32_t count;
};

static BOOL CALLBACK ts_monitor_proc(HMONITOR monitor, HDC dc, LPRECT rect, LPARAM param) {
    (void)monitor;
    (void)dc;
    struct ts_monitor_sink *sink = (struct ts_monitor_sink *)param;
    /* Keep counting past capacity: the RETURN value tells the caller whether
     * it saw every monitor, and silently stopping would make a truncated list
     * indistinguishable from a complete one. */
    if (sink->rects != NULL && sink->count < sink->capacity) {
        int32_t *slot = sink->rects + (sink->count * 4);
        slot[0] = rect->left;
        slot[1] = rect->top;
        slot[2] = rect->right - rect->left;
        slot[3] = rect->bottom - rect->top;
    }
    sink->count++;
    return TRUE;
}

int32_t ts_input_monitors(int32_t *out_rects, int32_t capacity) {
    struct ts_monitor_sink sink;
    sink.rects = out_rects;
    sink.capacity = capacity < 0 ? 0 : capacity;
    sink.count = 0;
    EnumDisplayMonitors(NULL, NULL, ts_monitor_proc, (LPARAM)&sink);
    return sink.count;
}

int32_t ts_input_window_rect(void *hwnd, int32_t *out_x, int32_t *out_y, int32_t *out_width,
                             int32_t *out_height) {
    RECT rect;
    if (hwnd == NULL || !GetWindowRect((HWND)hwnd, &rect)) {
        return 0;
    }
    if (out_x != NULL) {
        *out_x = rect.left;
    }
    if (out_y != NULL) {
        *out_y = rect.top;
    }
    if (out_width != NULL) {
        *out_width = rect.right - rect.left;
    }
    if (out_height != NULL) {
        *out_height = rect.bottom - rect.top;
    }
    return 1;
}

int32_t ts_input_is_elevated(void) {
    HANDLE token = NULL;
    TOKEN_ELEVATION elevation;
    DWORD size = sizeof(elevation);
    int32_t result = 0;

    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        return 0;
    }
    if (GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation), &size)) {
        result = elevation.TokenIsElevated ? 1 : 0;
    }
    CloseHandle(token);
    return result;
}

#else

/*
 * Off Windows every entry point is a no-op that reports "nothing injected",
 * so the Swift wrapper and everything above it compile and can be typechecked
 * on Linux CI. Same shape as WGCCaptureKit's stubs.
 */

int32_t ts_input_mouse_move(int32_t absolute_x, int32_t absolute_y) {
    (void)absolute_x;
    (void)absolute_y;
    return 0;
}

int32_t ts_input_mouse_button(int32_t absolute_x, int32_t absolute_y, int32_t button,
                              int32_t down) {
    (void)absolute_x;
    (void)absolute_y;
    (void)button;
    (void)down;
    return 0;
}

int32_t ts_input_scroll(int32_t absolute_x, int32_t absolute_y, int32_t wheel_y,
                        int32_t wheel_x) {
    (void)absolute_x;
    (void)absolute_y;
    (void)wheel_y;
    (void)wheel_x;
    return 0;
}

int32_t ts_input_key(uint16_t virtual_key, int32_t extended, int32_t down) {
    (void)virtual_key;
    (void)extended;
    (void)down;
    return 0;
}

void ts_input_virtual_desktop(int32_t *out_x, int32_t *out_y, int32_t *out_width,
                              int32_t *out_height) {
    if (out_x != NULL) {
        *out_x = 0;
    }
    if (out_y != NULL) {
        *out_y = 0;
    }
    if (out_width != NULL) {
        *out_width = 0;
    }
    if (out_height != NULL) {
        *out_height = 0;
    }
}

int32_t ts_input_monitors(int32_t *out_rects, int32_t capacity) {
    (void)out_rects;
    (void)capacity;
    return 0;
}

int32_t ts_input_window_rect(void *hwnd, int32_t *out_x, int32_t *out_y, int32_t *out_width,
                             int32_t *out_height) {
    (void)hwnd;
    (void)out_x;
    (void)out_y;
    (void)out_width;
    (void)out_height;
    return 0;
}

int32_t ts_input_is_elevated(void) { return 0; }

#endif
