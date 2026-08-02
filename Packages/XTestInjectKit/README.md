# XTestInjectKit

X11's **XTEST** extension behind the portable `InputInjecting` seam — the Linux
sharer's remote-control backend. What `SendInputKit` is on Windows and
`RemoteControlInjector` is on macOS.

```
Packages/XTestInjectKit
├── Sources/CXTestSys        systemLibrary over xtst.pc (apt libxtst-dev)
├── Sources/CXTestInject     the four Xlib calls + the keymap lookup
├── Sources/XTestInjectKit   the gate, the queue, the translation
└── Sources/xtest-probe      link check + keysym audit + live injection gate
```

## Why a C shim

Not the reason `CSendInput` has one. Nothing in Xlib is unrepresentable in
Swift; what the shim owns is the **display connection and the keymap**.

`XTestFakeKeyEvent` takes a *keycode* — a small integer identifying a physical
key on the machine currently running the X server, which depends on the loaded
keymap and is meaningless off-host. The wire carries USB HID usage IDs. Closing
that gap needs two hops, and only one of them is portable:

| hop | where it lives | testable |
|---|---|---|
| HID usage → **keysym** (`XK_Return`, a protocol constant) | `X11KeyCodeMapping`, in TailscreenProtocol | anywhere — `linux-protocol` runs it |
| keysym → **keycode** (`XKeysymToKeycode`) | this shim | only with a live `Display *` |

That split is the whole design. It is what makes the interesting half — 119
hand-written hex constants — checkable at all.

## Three things X11 does differently

- **Scrolling is buttons.** The core protocol has no wheel value: a scroll is a
  press-and-release of button 4 (up), 5 (down), 6 (left) or 7 (right), once per
  notch. So a continuous delta becomes a repeat count, with rounding (truncation
  would swallow every sub-line scroll) and a clamp (each notch is a real
  round trip to the server, so an unclamped count is a denial-of-service vector).
- **Nothing is injected without a flush.** Xlib queues requests client-side, so
  a batch that is never `XFlush`ed is a click that never happened. This is the
  single most likely way for the whole path to appear broken while every unit
  test passes, which is why `--live-check` exists.
- **Button numbers are 1/2/3 with middle as 2** — the opposite pairing to the
  wire enum's declaration order, hence a named function with a test rather than
  an inline `rawValue + 1`.

## XTEST is optional

Some remote and kiosk X servers ship without it. Without the extension every
`XTestFake*` call succeeds and injects nothing — so a sharer that assumed it was
present would grant control to a viewer whose every click silently vanishes.
`isTrusted()` probes at open, and the hosts withhold
`ScreenShareCaps.remoteControl` when it comes back false, so viewers hide
Request Control rather than sending requests into a void.

Under Wayland this reports whatever XWayland says, which is honest but limited:
injection reaches X11 clients and not native Wayland ones. The RemoteDesktop
portal is the answer there (Phase 3.3 of `plans/platform-alignment.md`).

## xtest-probe

```bash
xtest-probe --audit-keysyms   # every X11KeyCodeMapping row vs. Xlib's tables
xtest-probe --live-check      # real injection against $DISPLAY; MOVES THE CURSOR
xtest-probe                   # report what the display offers + a dry run
```

The audit catches a typo'd constant that lands on an *unassigned* keysym: the
mapping succeeds, `XKeysymToKeycode` returns 0, the keystroke is dropped, and
the only symptom is one key that does nothing. It cannot catch a typo landing on
a different *valid* keysym — that class is covered by the unit tests' spot rows.

The probe is also a **link check**: a SwiftPM library target is compiled but
never linked, so a missing `-lX11` stays invisible until something downstream
links it. That is exactly how WASAPIKit's missing GUIDs passed their own CI step
and failed eleven minutes later in the app.

CI runs all three in the `linux-xtest` leg of `build.yml`'s `linux-packages`
matrix, `--live-check` under Xvfb.

## The conformance is elsewhere

This package does **not** conform to `InputInjecting` — that would mean
depending on TailscreenSharer for one protocol. `X11InputInjector` in
`Packages/TailscreenLinuxBackends`'s `TailscreenSharerLinux` is the adapter,
and it does one piece of real work: resolving a `PickerSelection` to the
rectangle normalized coordinates map into. That rectangle is the **capture's**,
not the root's — `X11ScreenCapture` rounds both dimensions down to even for
I420, and a viewer's coordinates are relative to the frame it sees.
