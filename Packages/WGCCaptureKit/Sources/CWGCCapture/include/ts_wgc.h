// ts_wgc.h — a flat C surface over Windows.Graphics.Capture.
//
// Screen capture for the Windows sharer's `CaptureEncoding` backend, and the
// closest Windows analogue of what macOS does: WGC's `GraphicsCapturePicker` is
// `SCContentSharingPicker`, and a `GraphicsCaptureItem` is an `SCContentFilter`
// — a display OR a single window, chosen by the user in system UI.
//
// That parity is the reason for WGC over DXGI Desktop Duplication, which was
// written first and deleted. Duplication is simpler and needs no WinRT, but it
// captures a whole output and nothing else — so a sharer built on it could only
// ever answer `PickerSelection.kind == .display`, and the app's share flow would
// have been shaped around a limitation the macOS app does not have.
//
// **Raw WinRT ABI, not C++/WinRT.** cppwinrt leans on MSVC's standard library,
// and MSVC's STL hard-asserts a compiler version the Swift toolchain's clang
// does not satisfy (see WASAPIKit's ts_wasapi.cpp — `error STL1000`). So this
// drives the ABI interfaces directly: `RoGetActivationFactory`, vtable calls,
// manual HSTRINGs. C++ is still required for `__uuidof`, which reads each IID
// out of the SDK header's own annotation instead of a hand-copied GUID.
//
// Everything is `#ifdef _WIN32`; elsewhere the translation unit is empty.

#ifndef TS_WGC_H
#define TS_WGC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A chosen capture target — a display or a window. Outlives the session that
/// captures it, so a share can be restarted against the same selection.
typedef struct ts_wgc_item ts_wgc_item;

/// An open capture session on an item.
typedef struct ts_wgc ts_wgc;

enum {
    TS_WGC_OK = 0,
    TS_WGC_ERR_ARGUMENT = -1,
    /// No new frame within the timeout. **Not an error** — WGC produces a frame
    /// only when the target actually changes, so a still screen times out
    /// continuously and the caller re-encodes what it already has.
    TS_WGC_TIMEOUT = -2,
    /// The target went away: the window closed, or the display was
    /// disconnected. The macOS sharer treats the same event as
    /// `source-gone`/`.sourceClosed` and tears the share down gently.
    TS_WGC_ERR_CLOSED = -3,
    /// The user dismissed the picker without choosing.
    TS_WGC_ERR_CANCELLED = -4,
    /// This Windows build has no WGC (pre-1803) or it is policy-disabled.
    TS_WGC_ERR_UNAVAILABLE = -5,
    /// A frame is already mapped; release it before acquiring another.
    TS_WGC_ERR_BUSY = -6,
};

/// Whether WGC exists at all on this machine, checked before any UI is shown so
/// a missing feature is a message rather than a failed share.
int32_t ts_wgc_is_supported(void);

/// Show the system picker and block until the user chooses or cancels.
///
/// MUST be called on the UI thread: the picker is modal system UI and needs an
/// owner window (`IInitializeWithWindow`) and a message pump. This pumps
/// messages while waiting, which is what a modal dialog does anyway — the
/// alternative is a hand-written IAsyncOperation completion handler in raw ABI,
/// whose failure mode is a silent hang.
///
/// - owner_hwnd: the app's window, which the picker parents itself to.
int32_t ts_wgc_pick(void *owner_hwnd, ts_wgc_item **out);

/// Build an item directly, without UI — for restarting a share against a
/// remembered target, which is what the macOS capture-helper respawn does.
int32_t ts_wgc_item_for_monitor(void *hmonitor, ts_wgc_item **out);
int32_t ts_wgc_item_for_window(void *hwnd, ts_wgc_item **out);

/// The item's display name, UTF-8, truncated to `capacity`. The picker already
/// showed it; this is for the sharer's own "you are sharing X" label.
int32_t ts_wgc_item_name(ts_wgc_item *item, char *buffer, int32_t capacity);

void ts_wgc_item_release(ts_wgc_item *item);

/// Start capturing an item.
///
/// Safe to call from any thread; the frame pool is created free-threaded so
/// frames can be pulled from the capture thread rather than the UI one.
int32_t ts_wgc_open(ts_wgc_item *item, ts_wgc **out, uint32_t *width, uint32_t *height);

/// Wait up to `timeout_ms` for a frame and map it for reading. On TS_WGC_OK the
/// caller owns the mapping until ``ts_wgc_release``.
///
/// - stride: the ROW PITCH in bytes, the driver's, routinely wider than
///   `width * 4`. Reading at `width * 4` skews the image further every row.
int32_t ts_wgc_acquire(
    ts_wgc *handle, uint32_t timeout_ms, const uint8_t **bgra, int32_t *stride);

void ts_wgc_release(ts_wgc *handle);
void ts_wgc_close(ts_wgc *handle);

#ifdef __cplusplus
}
#endif

#endif  // TS_WGC_H
