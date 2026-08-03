#ifndef TS_DRAW_SURFACE_H
#define TS_DRAW_SURFACE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The surface the **sharer** draws on: a topmost popup covering the shared
/// region that takes the pointer and the keyboard, for as long as a drawing
/// tool is armed and not one moment longer.
///
/// ## Why this is a second window and not a flag on `ts_overlay`
///
/// `ts_overlay` is the window that shows what *viewers* draw. It is
/// `WS_EX_TRANSPARENT | WS_EX_NOACTIVATE`, and both are load-bearing: it sits
/// over the sharer's own desktop for the entire share, and a share is mostly
/// spent not drawing. Turning it interactive would mean clearing
/// `WS_EX_TRANSPARENT`, clearing `WS_EX_NOACTIVATE`, flipping the
/// `WM_NCHITTEST`/`HTTRANSPARENT` answer, taking focus, and then *restoring all
/// four* — and the cost of getting the restore wrong is a desktop that eats
/// every click until the process dies.
///
/// A separate window turns that restore into a `DestroyWindow`. Disarming is
/// then not a sequence to get right but an object that stops existing, and the
/// window does not exist at all until a tool is armed. That asymmetry is the
/// whole argument: the dangerous state should be the one that has to be
/// actively created.
///
/// ## Why it is visible
///
/// It paints a dim wash, an accent border and a caption strip. An *invisible*
/// fullscreen click-swallower is the trap in its purest form — the sharer's
/// machine simply stops responding to the mouse with nothing on screen to
/// explain it. The wash is the feedback, and the caption carries the way out
/// where it will still be legible after the hub window has disappeared behind
/// this one.
///
/// It is excluded from capture (`WDA_EXCLUDEFROMCAPTURE`, as `ts_overlay` is),
/// so viewers never see the sharer's screen dim.
///
/// ## Why it owns a thread
///
/// Same reason `ts_overlay` does, and see its header for the full version: a
/// window belongs to the thread that created it, and one whose thread never
/// pumps is one Windows treats as hung. This one needs the pump even more —
/// it is the thing receiving the input.
typedef struct ts_draw_surface ts_draw_surface;

/// A pointer event, in **client pixels** of the surface (so, of the shared
/// region). `phase` is 0 = pressed, 1 = dragged, 2 = released.
///
/// Fires on the surface's own pump thread. Coordinates may be negative or past
/// the region: a drag that leaves the window keeps reporting while the button
/// is held, which is deliberate — the caller clamps.
typedef void (*ts_draw_pointer_cb)(void *context, int32_t phase, int32_t x, int32_t y);

/// "Stop drawing" — the sharer pressed Escape, **or the surface lost the
/// keyboard**.
///
/// One callback for both because they are one situation: the way out is no
/// longer reachable. Losing focus is the Windows-specific half — unlike an X11
/// override-redirect window, this one is an ordinary top-level that Alt-Tab,
/// the Windows key or a UAC prompt can take the keyboard from, leaving a window
/// that still swallows the mouse and an Escape key that goes somewhere else.
///
/// Fires on the pump thread. **The handler must not destroy the surface
/// synchronously** — that would join the thread it is running on. Hop first.
typedef void (*ts_draw_release_cb)(void *context);

/// Outcomes of `ts_draw_surface_create`, written through `out_status`.
#define TS_DRAW_OK 0
/// The window could not be built at all (off Windows, or `CreateWindowEx`
/// failed).
#define TS_DRAW_NO_SURFACE 1
/// The window came up but did not end up with the keyboard, so Escape could not
/// have got the sharer back out. It is torn down again rather than left up:
/// refusing to arm is the only safe answer.
#define TS_DRAW_NO_KEYBOARD 2

/// Create the surface, show it, and take the keyboard — all or nothing.
///
/// - Returns: the surface on success, NULL otherwise, with the reason in
///   `out_status` (may be NULL).
///
/// Coordinates are virtual-desktop pixels and the process must be per-monitor
/// DPI aware, exactly as for `ts_overlay_create`.
///
/// Safe from any thread; the window is built on the surface's own thread and
/// this waits for the answer. Note that `SetForegroundWindow` only succeeds for
/// a process that is already the foreground one — which it is, because a person
/// just clicked a tool in this app's window. Called from a background process
/// it will fail the focus check and refuse, which is the correct answer.
ts_draw_surface *ts_draw_surface_create(int32_t x, int32_t y, int32_t width, int32_t height,
                                        void *context, ts_draw_pointer_cb on_pointer,
                                        ts_draw_release_cb on_release, int32_t *out_status);

/// Tear the surface down. Idempotent against a NULL surface, and safe to call
/// from anywhere except the callbacks above.
///
/// No callback fires after this returns.
void ts_draw_surface_destroy(ts_draw_surface *surface);

#ifdef __cplusplus
}
#endif

#endif /* TS_DRAW_SURFACE_H */
