# X11HotkeyKit

A **system-wide hotkey on X11**, via `XGrabKey`. What `RegisterHotKey` is on
Windows (`Packages/WinHotkeyKit`) and Carbon's `RegisterEventHotKey` is on
macOS (`Apps/macOS/Sources/GlobalHotkey.swift`).

It exists for one row: **mute from outside the window.** The in-window
microphone buttons only reach you while the app is in front of you, and during
a share the app is behind whatever you are demonstrating — which is exactly
when muting matters.

## What is here, and what deliberately is not

| Piece | Where | Why |
|---|---|---|
| Chord → keysym + modifier mask | `TailscreenProtocol.X11HotkeyMapping` | Pure arithmetic over `X11KeyCodeMapping`, so Linux CI tests it with no X server |
| The lock-key mask variants | `X11HotkeyMapping.grabMasks` | Same |
| Auto-repeat collapse | `TailscreenProtocol.GlobalHotkeyRepeatFilter` | Same |
| Whether to try at all | `X11HotkeySupport.decide` (here, pure) | The case that matters — Wayland — cannot be reproduced under Xvfb, but a function over three environment strings can |
| `Display *`, `XKeysymToKeycode`, `XGrabKey`, event drain | `Sources/CX11Hotkey` | Needs a live server; nothing else does |

**Separate from `XTestInjectKit`** even though both are thin Xlib shims. That
package *writes* input for the sharer's remote control; this one *reads* one
chord for the local user. A viewer-only run wants this and must not link an
injector it will never call — and the sharer's injector must not grow a
keyboard grab, which is the one thing on X11 that can stop the rest of the
desktop receiving a key.

## Three things that fail silently, and what catches each

- **A grab that was refused.** `XGrabKey` reports `BadAccess` *asynchronously*.
  Without an error handler plus `XSync`, taking a chord another app owns
  returns success and the user gets a hotkey that never fires with nothing
  anywhere saying why. `x11-hotkey-probe --live-check` grabs the chord twice
  and requires the second to be refused.
- **Num Lock.** `XGrabKey` matches modifier state *exactly*, so a grab under
  `Ctrl|Alt` stops matching the instant `Mod2` joins it. The same live check
  presses the chord with Num Lock on.
- **A Wayland session.** `XGrabKey` succeeds against XWayland and then
  under-delivers: the chord fires while an X11 app is focused and does nothing
  while a native Wayland one is. `X11HotkeySupport` refuses up front — the same
  capability-honesty rule as `XTestInjector.isTrusted()` and
  `ts_gtk_overlay_supported()`. Wayland's real answer is the GlobalShortcuts
  portal, which is separate work.

## It polls; it owns no thread

X11 has no "post to the app's loop" primitive that does not mean threading
Xlib, and both GUI hosts already service their transport from one main-thread
tick. So the grab connection is its own `Display *` and the host drains it from
that tick — no thread, no lock, no callback crossing a thread boundary. The
Windows shim owns a thread instead, because `RegisterHotKey` gives it no
choice.

## Build

```bash
sudo apt install libx11-dev libxtst-dev xvfb   # libxtst is for the probe only
export PKG_CONFIG_PATH="$PWD/Packages/TailscaleKit"
swift test  --package-path Packages/X11HotkeyKit
swift build --package-path Packages/X11HotkeyKit --product x11-hotkey-probe
xvfb-run -a Packages/X11HotkeyKit/.build/debug/x11-hotkey-probe --live-check
```

CI leg: `linux-hotkey`.
