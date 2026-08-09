# SendInputKit

Win32 `SendInput` behind the portable `InputInjecting` seam — the Windows
sharer's remote-control backend, i.e. what `RemoteControlInjector` is on macOS.

Nothing to install: `SendInput` lives in `user32`, which ships with Windows.

## Why there is a C shim

`INPUT` carries an **anonymous union** of `MOUSEINPUT` / `KEYBDINPUT` /
`HARDWAREINPUT`. Swift imports anonymous unions as a synthesized nested type
whose spelling is a clang implementation detail, so constructing one from Swift
works right up until a toolchain bump renames it. From C it is a struct.

The shim is therefore as small as it can be — a handful of Win32 calls with no
decisions in them. Everything with a decision lives in Swift, and the pure
arithmetic lives further out still, in `TailscreenProtocol`:

| Piece | Where | Why there |
|---|---|---|
| `ts_sendinput.c` | this package | anonymous unions, and nothing else |
| `SendInputInjector` | this package | the gate, ordering, modifier synthesis |
| `WindowsPointerMapping` | TailscreenProtocol | normalized → absolute arithmetic |
| `WindowsKeyCodeMapping` | TailscreenProtocol | HID usage ↔ (VK, extended) |

The split is what makes the interesting parts testable on Linux CI.

## What is different from macOS

**There is no permission to ask for.** macOS gates `CGEventPost` behind
Accessibility TCC, so the mac injector refuses a grant when untrusted and can
raise a prompt. Windows has no equivalent: injection is governed by UIPI, which
silently discards input aimed at a window running at a *higher integrity level*
than the sender. There is nothing to request and nothing to grant — an
unelevated process cannot drive an elevated one and never will. So `isTrusted()`
returns true, and `canDriveElevatedWindows` reports the one thing that varies,
so a sharer can explain why the remote pointer works everywhere except Task
Manager instead of leaving it a mystery.

**Modifiers are real key events.** A `CGEvent` carries its modifier flags as a
field. `SendInput` does not: Windows reports whatever state the keyboard is
actually in, so the only way to deliver Ctrl+C is to press Ctrl, press C,
release C, release Ctrl. `SendInputInjector` presses the snapshot's modifiers
around each key and releases them in reverse order.

They are pressed per key rather than tracked across events because the protocol
deliberately sends modifier state as a *snapshot* on every event rather than as
separate key events — which keeps mid-stream joins stateless, and means there is
no "modifier down" message to pair with. The cost is a redundant press/release
per key in a held-modifier sequence; the benefit is that a dropped connection
can never strand a modifier held down on the sharer's machine.

Caps Lock is excluded: it is a toggle, not a held modifier, and synthesizing a
press would flip the sharer's real Caps state and leave it flipped.

**Position and click go in one call.** `SendInput` delivers a batch atomically,
so a press is sent together with its move — otherwise another process's cursor
motion can land between them and a remote click arrives somewhere the viewer did
not aim it.

## The geometry gap

`activate(selection:)` exists so an injector can look up where the shared
content is: on macOS a `PickerSelection` carries a `CGDirectDisplayID` or a
`CGWindowID`. A WGC `GraphicsCaptureItem` carries neither — it is an opaque
object with a size and a display name, with no HMONITOR or HWND to ask.

So `WindowsInputInjector` (in TailscreenSharerWGC) takes the region as a
closure from whoever built the item, and the host supplies an injector *only*
when it knows the geometry. Without one the server withholds
`ScreenShareCaps.remoteControl` and viewers hide Request Control. A click
landing somewhere the viewer did not aim it is worse than a click that does not
happen.

Unblocking the picker path means recovering the target's rect after the fact —
matching the item's reported size against `EnumDisplayMonitors`, and declining
when it is ambiguous.

## Testing

```bash
swift test --package-path Packages/SendInputKit
```

Runs anywhere, Linux included: every assertion goes through
`onInjectForTesting`, so no real `SendInput` runs and no cursor moves. The
virtual desktop is injectable (`virtualDesktopProvider`) for the same reason —
read from `GetSystemMetrics` it would be whatever monitors the test machine
happens to have, on Windows runners too.

`sendinput-probe` is a manual test that used to double as CI's link check. It
prints the virtual desktop and the absolute coordinates a corner click would
produce, and injects **nothing** unless passed `--inject`. CI no longer builds
it — the Windows app links SendInputKit itself, so `Build the app` is the link
gate — and CI never ran it: unlike `wasapi-probe`, whose failure mode is
silence, this one moves a real cursor.
