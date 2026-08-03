# WinHotkeyKit

A **system-wide hotkey on Windows**, via `RegisterHotKey`. What
`Packages/X11HotkeyKit` is on Linux and `Apps/macOS/Sources/GlobalHotkey.swift`
is on macOS.

It exists for the same row as its siblings: **mute from outside the window** —
the in-window microphone buttons only reach you while the app is in front of
you, and during a share it is not.

## Why it owns a thread

`RegisterHotKey(NULL, …)` posts `WM_HOTKEY` as a **thread message** to the
thread that registered, delivered to whatever pumps that thread's queue. In the
WinUI app that pump is XAML's, which removes thread messages and dispatches
them nowhere — so the app would register successfully and receive nothing. The
shim therefore owns a thread with a plain `GetMessage` loop, the same answer
`WinOverlayKit` reaches for its layered window and for a related reason: a
Windows message queue belongs to exactly one thread and cannot be politely
shared.

The chord is fixed at creation; changing it is destroy + create. That is what
the host does anyway — it holds the chord only while there is a microphone to
mute — and it keeps the thread's job to "register once, then pump", with no
cross-thread marshalling of a registration request.

## What is proven, and where

| Claim | Proven by | Runs on |
|---|---|---|
| The `fsModifiers` + `vk` handed to `RegisterHotKey` are right | `GlobalHotkeyMappingTests` (`WindowsHotkeyMapping`) | Linux CI (`linux-hotkey`) |
| Every registration carries `MOD_NOREPEAT` | Same | Linux CI |
| An unregistrable chord is refused before any syscall | `WindowsHotkeyKitTests` | Linux CI |
| A platform with no `RegisterHotKey` says so rather than pretending | Same | Linux CI |
| The package **links** against user32 | `winhotkey-probe` | Windows CI |
| `RegisterHotKey` accepts what the mapping produced | `winhotkey-probe` (run, not just built) | Windows CI |
| `WM_HOTKEY` reaches the pump thread while **another app is focused** | `winhotkey-probe --hold` | **A person at a Windows desk — unverified in CI** |

That last row is the honest limit, stated the way `WASAPIKit`'s README states
its own: there is no `RegisterHotKey` off Windows and nothing stands in for
one. `MOD_NOREPEAT` handling, the pump thread's shutdown, and the behaviour
under a focused foreign application have not been exercised by any automated
gate in this repository.

## Build

```bash
export PKG_CONFIG_PATH="$PWD/Packages/TailscaleKit"
swift test  --package-path Packages/WinHotkeyKit          # decisions + syntax, anywhere
swift build --package-path Packages/WinHotkeyKit --product winhotkey-probe
swift run   --package-path Packages/WinHotkeyKit winhotkey-probe          # Windows: register + release
swift run   --package-path Packages/WinHotkeyKit winhotkey-probe --hold   # Windows: manual gate
```

Nothing to install — `RegisterHotKey` ships with Windows.
