#ifndef TS_XTEST_H
#define TS_XTEST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Injection primitives over X11's XTEST extension — the Linux sharer's
/// remote-control backend, i.e. what `SendInput` is on Windows and
/// `CGEventPost` is on macOS.
///
/// The reason for a C shim here is different from `CSendInput`'s. Nothing in
/// Xlib is unrepresentable in Swift; what it owns instead is the **connection
/// and the keymap**. `XTestFakeKeyEvent` takes a *keycode* — a small integer
/// identifying a physical key on the machine currently running the X server,
/// meaningless off-host — while the wire carries HID usages and
/// `X11KeyCodeMapping` turns those into *keysyms*. Closing that last gap needs
/// `XKeysymToKeycode`, which needs a live `Display *`. So the display lives
/// here, and every decision lives in Swift.
///
/// **Not thread-safe, deliberately.** A `Display *` is not, and the Swift
/// injector already funnels every event through one serial queue for ordering
/// reasons, so adding `XInitThreads` would buy a guarantee nothing needs and
/// cost a global that affects the whole process (including GTK's own display
/// connection in the app that links this).

/// Open a connection for injection. `display_name` may be NULL for `$DISPLAY`.
///
/// Returns NULL when there is no display, or when the server lacks XTEST.
/// The second is the interesting failure: XTEST is an optional extension and
/// some remote/kiosk X servers ship without it, in which case every call below
/// would silently succeed and inject nothing. Checking once at open is what
/// turns that into a grant the sharer can be told was refused.
void *ts_xtest_open(const char *display_name);

/// Close the connection. Safe on NULL.
void ts_xtest_close(void *handle);

/// Move the pointer to (`x`, `y`) in ROOT-WINDOW pixels.
///
/// Root pixels, not the 0…65535 abstraction `SendInput` wants — X11 has no
/// such rescale, which is why the Linux mapping is one stage where the
/// Windows one is two.
void ts_xtest_motion(void *handle, int32_t x, int32_t y);

/// Press or release an X11 button number: 1 left, 2 middle, 3 right, and
/// 4/5/6/7 for scroll up/down/left/right. `down` non-zero for press.
///
/// Note the button numbering is X11's own and does NOT match the wire enum's
/// order — middle is 2 and right is 3. `X11PointerMapping.buttonNumber` owns
/// that translation and is tested.
void ts_xtest_button(void *handle, int32_t button, int32_t down);

/// Press or release the key that currently produces `keysym`.
///
/// Returns non-zero if a key was injected, 0 if this server's keymap has no
/// keycode for that keysym — which is a real, routine outcome (a US keymap
/// has no key for `XK_ediaeresis`) and must be reported rather than swallowed,
/// so the caller can drop the keystroke instead of believing it landed.
int32_t ts_xtest_key(void *handle, uint32_t keysym, int32_t down);

/// The root window's pixel size, for the region normalized coordinates map
/// into. Writes 0s on failure.
void ts_xtest_root_size(void *handle, int32_t *out_width, int32_t *out_height);

/// Flush queued requests to the server.
///
/// Injection is asynchronous: `XTestFake*` only queues, so a batch that is
/// never flushed is a click that never happens. The Swift side flushes once
/// per drained batch rather than per event, which is also what makes a
/// press+release pair arrive together.
void ts_xtest_flush(void *handle);

/// The pointer's current position on the root window. Writes -1s on failure.
///
/// Exists for the live self-check: injection is fire-and-forget, so without
/// reading the pointer back there is no way to tell "XTEST worked" from
/// "XTEST is present but the server ignored us" — and the whole reason this
/// backend gates on `isTrusted()` is that the second failure is silent.
void ts_xtest_pointer_position(void *handle, int32_t *out_x, int32_t *out_y);

/// `XKeysymToString`, for diagnostics. Returns NULL for a keysym the server's
/// tables do not name — which is how `xtest-probe` detects a typo'd constant
/// in `X11KeyCodeMapping` that happens to land on an unassigned value.
const char *ts_xtest_keysym_name(uint32_t keysym);

#ifdef __cplusplus
}
#endif

#endif
