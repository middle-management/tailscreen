#ifndef TS_X11HOTKEY_H
#define TS_X11HOTKEY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A system-wide hotkey on X11, via `XGrabKey` — what `RegisterHotKey` is on
/// Windows and Carbon's `RegisterEventHotKey` is on macOS.
///
/// **Why a C shim.** The same reason `CXTestInject` has one and not a line
/// more: this owns a `Display *` and the keymap lookup. `XGrabKey` takes a
/// *keycode*, which names a physical key on the machine running the server and
/// is meaningless off-host, while `ShortcutCatalog` describes a chord and
/// `X11HotkeyMapping` turns it into a *keysym*. Closing the last hop needs
/// `XKeysymToKeycode`, which needs a live display. Every decision — which
/// keysym, which modifier mask, which lock-key variants, what counts as a
/// repeat — is Swift, in the portable tier, where Linux CI runs it.
///
/// **It polls; it owns no thread.** X11 has no "post to the app's loop"
/// primitive that does not mean threading Xlib, and both GUI hosts already
/// service their transport from one main-thread tick. So the grab connection is
/// its own `Display *` and the host drains it from that tick. No thread, no
/// lock, no callback crossing a thread boundary into Swift — which is a
/// meaningfully smaller surface than the alternative, and the one place this
/// differs from the Windows shim, where `RegisterHotKey` gives no choice.
///
/// **Not thread-safe, deliberately** — a `Display *` is not, and everything
/// here is called from the host's main thread.

/// Open a grab connection. `display_name` may be NULL for `$DISPLAY`.
/// Returns NULL when there is no display to open.
void *ts_hotkey_open(const char *display_name);

/// Close it, releasing any grab. Safe on NULL.
void ts_hotkey_close(void *handle);

/// Whether the server honoured `XkbSetDetectableAutoRepeat`.
///
/// With it, holding the chord delivers repeated `KeyPress` with no interleaved
/// `KeyRelease`, which the caller's latch collapses to one activation. Without
/// it, a held key delivers release/press pairs indistinguishable from real
/// ones and the mute would flip at the keyboard repeat rate. Reported rather
/// than assumed so the host can say so; every X server since XKB shipped
/// supports it, including Xvfb.
int32_t ts_hotkey_detectable_autorepeat(void *handle);

/// Grab `keysym` under each of `count` modifier masks on the root window.
///
/// The list is the caller's, and it matters: `XGrabKey` matches modifier state
/// EXACTLY, so a chord grabbed only under `Ctrl|Alt` stops firing the moment
/// Num Lock is on. `X11HotkeyMapping.grabMasks` enumerates the variants.
///
/// Returns 1 on success, 0 on refusal — no keycode for that keysym on this
/// keymap, or `BadAccess` because another client already holds the chord. The
/// refusal is the interesting half: `XGrabKey` reports errors ASYNCHRONOUSLY,
/// so without the error handler + `XSync` below the call "succeeds" and the
/// key silently never fires. Every grab installed before the failure is undone
/// before returning, so a partial grab never survives.
int32_t ts_hotkey_grab(void *handle, uint32_t keysym, const uint32_t *masks, int32_t count);

/// Release the grab. Safe to call when nothing is grabbed.
void ts_hotkey_ungrab(void *handle);

/// Drain pending key events into `out_events`: 1 for press, 0 for release.
///
/// Returns how many were written (0 when idle), or -1 for a bad argument.
/// Non-blocking — it consults `XPending` and never waits, so a host can call it
/// from a UI tick without risking a stall.
int32_t ts_hotkey_poll(void *handle, int32_t *out_events, int32_t capacity);

#ifdef __cplusplus
}
#endif

#endif
