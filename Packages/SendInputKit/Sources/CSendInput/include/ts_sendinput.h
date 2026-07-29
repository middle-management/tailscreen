#ifndef TS_SENDINPUT_H
#define TS_SENDINPUT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Injection primitives over Win32 `SendInput`, flattened so Swift never has
/// to build an `INPUT`.
///
/// The reason for a C shim here is narrow and specific: `INPUT` carries an
/// ANONYMOUS UNION of `MOUSEINPUT` / `KEYBDINPUT` / `HARDWAREINPUT`, and Swift
/// imports anonymous unions as a synthesized nested type whose spelling is a
/// clang implementation detail. Building one from Swift is possible and
/// unstable; building one from C is neither.
///
/// Every function returns the number of events actually injected — 0 means
/// the OS refused, which is what UIPI does when a lower-integrity process
/// targets a higher-integrity window. Callers should treat 0 as "the
/// permission is missing", not as a transient failure.

/// Absolute coordinates over the VIRTUAL DESKTOP, 0…65535 on both axes. Use
/// `WindowsPointerMapping` (TailscreenProtocol) to produce them: the scaling
/// has three separate ways to be wrong and is unit-tested there.
int32_t ts_input_mouse_move(int32_t absolute_x, int32_t absolute_y);

/// `button`: 0 left, 1 right, 2 middle. `down` non-zero for press.
///
/// The move is folded in rather than left to the caller: `SendInput` delivers
/// a batch atomically, so a press sent with its position cannot have another
/// process's cursor motion interleaved between them.
int32_t ts_input_mouse_button(int32_t absolute_x, int32_t absolute_y, int32_t button,
                              int32_t down);

/// Wheel units (`WHEEL_DELTA` == 120 per detent), vertical then horizontal.
/// Either may be zero; both zero injects nothing.
int32_t ts_input_scroll(int32_t absolute_x, int32_t absolute_y, int32_t wheel_y,
                        int32_t wheel_x);

/// `virtual_key` is a Win32 VK code and `extended` selects the extended-key
/// flag — together they are the identity of a key on Windows, which is why
/// `WindowsKeyCodeMapping` keys its table on the pair. `down` non-zero for
/// press.
int32_t ts_input_key(uint16_t virtual_key, int32_t extended, int32_t down);

/// The virtual desktop's bounds in screen pixels. `x`/`y` are NEGATIVE when a
/// monitor sits left of or above the primary one.
void ts_input_virtual_desktop(int32_t *out_x, int32_t *out_y, int32_t *out_width,
                              int32_t *out_height);

/// A window's bounds in screen pixels. Returns 0 if the window is gone.
int32_t ts_input_window_rect(void *hwnd, int32_t *out_x, int32_t *out_y, int32_t *out_width,
                             int32_t *out_height);

/// Whether this process can inject into the foreground window.
///
/// Windows has no Accessibility-style prompt: injection is governed by UIPI,
/// which silently discards input aimed at a HIGHER integrity level than the
/// sender. So there is nothing to ask for — an unelevated app simply cannot
/// drive an elevated one — and the only honest answer is whether the process
/// is elevated. Reported so the sharer can say why a click did nothing
/// instead of leaving the viewer to guess.
int32_t ts_input_is_elevated(void);

#ifdef __cplusplus
}
#endif

#endif /* TS_SENDINPUT_H */
