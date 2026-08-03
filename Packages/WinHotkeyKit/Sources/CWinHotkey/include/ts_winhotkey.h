#ifndef TS_WINHOTKEY_H
#define TS_WINHOTKEY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A system-wide hotkey on Windows, via `RegisterHotKey` — what `XGrabKey` is
/// on Linux (X11HotkeyKit) and Carbon's `RegisterEventHotKey` is on macOS.
///
/// **Why it owns a thread.** `RegisterHotKey(NULL, …)` posts `WM_HOTKEY` as a
/// THREAD message to the thread that registered, and it is delivered to
/// whatever pumps that thread's queue. In the WinUI app that pump is XAML's,
/// which removes thread messages and dispatches them nowhere — so the app
/// would register successfully and receive nothing. Owning a thread with a
/// plain `GetMessage` loop is the same answer `WinOverlayKit` reaches for its
/// layered window, and for a related reason: a Windows message queue belongs
/// to exactly one thread and cannot be politely shared.
///
/// This is the one structural difference from the X11 shim, which polls its own
/// display connection from the host's main thread and owns no thread at all.
/// The API above it is the same shape either way: the host asks how many
/// activations have accumulated.
///
/// **The chord is fixed at creation.** Changing it means destroy + create,
/// which is what the host does anyway — it holds the chord only while there is
/// a microphone to mute — and it keeps the thread's job to "register once, then
/// pump", with no cross-thread marshalling of a registration request.
///
/// Off Windows every entry point is a stub that fails: the wrapper above
/// reports `.unsupportedPlatform`, and Linux CI still typechecks the Swift.

/// Start the pump thread and register `modifiers` + `virtual_key`
/// (`RegisterHotKey`'s `fsModifiers` and `vk`, from `WindowsHotkeyMapping`).
///
/// Returns NULL when the thread could not start or the registration was
/// refused — `ERROR_HOTKEY_ALREADY_REGISTERED` being the one that actually
/// happens, i.e. another application owns the combo. Reported rather than
/// swallowed: a hotkey the app advertises but did not get is worse than one it
/// never claimed, because the user has no reason to doubt it.
void *ts_winhotkey_create(uint32_t modifiers, uint32_t virtual_key);

/// Unregister, stop the pump thread, and free. Safe on NULL.
void ts_winhotkey_destroy(void *handle);

/// How many activations have accumulated since the last call, resetting the
/// count. `MOD_NOREPEAT` (set by `WindowsHotkeyMapping`) means a held chord
/// contributes exactly one, so no equivalent of the X11 repeat latch is needed
/// here.
int32_t ts_winhotkey_take(void *handle);

/// Whether this build has a `RegisterHotKey` at all — 0 off Windows.
int32_t ts_winhotkey_supported(void);

#ifdef __cplusplus
}
#endif

#endif
