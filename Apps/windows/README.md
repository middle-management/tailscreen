# tailscreen-windows

The native Windows desktop app — swift-cross-ui on WinUI, reusing the same
portable core as the macOS and Linux apps.

**Status: UI stage (W2).** It renders and runs. It does not yet reach a tailnet
or decode video; those are W3–W5 in `docs/viewer-windows-plan.md`. What this
stage proves is that Swift, swift-cross-ui's WinUI backend and Tailscreen's
portable tiers all build and run together on Windows — none of which had ever
been tried before.

## Testing it on a Windows machine

You do not need a Swift toolchain to try it. Every push that touches this app
builds it in the `Windows build` workflow and attaches the app together with
the Swift runtime it needs:

1. Open the latest **Windows build** run in the repository's Actions tab.
2. Download the **`tailscreen-windows-swift6.1`** artifact.
3. Unzip it **keeping the folder intact**, and run `tailscreen-windows.exe`
   from inside that folder.

Keeping the folder together is the part that matters. Swift links its runtime
dynamically on Windows, so the exe on its own dies before `main` with

> The code execution cannot proceed because swiftCore.dll was not found

and then, once that one is satisfied, the same dialog again for
`swift_Concurrency.dll`, `Foundation.dll` and so on down the chain. The
artifact ships those DLLs beside the exe, and Windows searches the
executable's own directory first — so this needs no installer, no PATH edit and
no admin rights, but it does mean the exe must stay next to its DLLs.

CI checks this rather than assuming it: after staging, the workflow launches
the binary and fails the build on `STATUS_DLL_NOT_FOUND` (0xC0000135) or
`STATUS_ENTRYPOINT_NOT_FOUND` (0xC0000139), so a missing DLL is caught on the
runner instead of on your desktop.

The other thing the folder must contain is the **Windows App SDK bootstrapper**,
at exactly this path beside the exe:

```
swift-winui_CWinAppSDK.resources\Microsoft.WindowsAppRuntime.Bootstrap.dll
```

`swift-winui`'s `WindowsAppRuntimeInitializer` looks it up at that literal
relative path and nowhere else; when it isn't there it throws, and
`SwiftApplication.main` turns that into `fatalError`, so the app quits
instantly having successfully loaded every DLL it needs. An earlier version of
the CI staging flattened the build tree's DLLs into one directory, which put
that file somewhere the lookup doesn't check — the app aborted identically on
the runner and on a real desktop, and the staging step now asserts the exact
path rather than an approximation of it.

If the machine has no Windows App Runtime installed, the bootstrapper runs
`WindowsAppRuntimeInstaller.exe` when it is present beside the exe (the
artifact ships it when the build tree provides it), and otherwise prompts.

A Swift trap surfaces on Windows as either `0xC000001D` (illegal instruction,
`ud2`) or `0xC0000409` (`__fastfail`); both have been observed from identical
sources, so neither is the signature to look for. The message itself goes to
stdout, which is why the app is still a console binary — see below.

## Why a console window appears

The executable is built for the console subsystem, so launching it opens a
terminal alongside the UI. That is deliberate for now: everything diagnostic
this app emits — including the bootstrapper failure above — is a `print` to
stdout, and a windows-subsystem binary would discard it. Run it **from an
already-open terminal** rather than double-clicking, or the window closes with
the message before it can be read.

Linking with `/SUBSYSTEM:WINDOWS` is the fix once the app reliably starts.

A window should appear with the app name, a status line, and a **Check
environment** button. Clicking it reads real values out of the portable
`TailscreenProtocol` tier and updates the status line — which is the actual
point of this stage: a window that paints but can't reach the shared core would
be a dead end, and only clicking proves the event loop, the observable update
and the repaint all work.

If the window appears and the button changes the text, the stage is good.

### Known limits at this stage

- No tailnet, no peer list, no video. The app talks to nothing.
- x86_64 only. arm64 Windows is untested and unbuilt.
- Unsigned, so SmartScreen will warn on first run.

## Building it yourself

Needs the [swift.org Windows toolchain](https://www.swift.org/install/windows/)
(6.1 is what CI uses — 6.0.3 fails on `ucrt`, see `windows-build.yml`) and the
Windows App SDK that swift-cross-ui's `WinUIBackend` targets.

Installing the toolchain also puts the runtime DLLs on PATH, which is the other
way to run a bare `tailscreen-windows.exe` if you have one lying around without
its folder.

```powershell
swift build --package-path Apps\windows --product tailscreen-windows
```

**Clone with symlinks enabled**, or the build fails before it starts:

```powershell
git config --global core.symlinks true
git clone --recurse-submodules https://github.com/middle-management/tailscreen.git
```

`Packages/TailscaleKit/Sources` and `include/` are symlinks into the
libtailscale submodule. Without symlink support git writes them as text files
containing their target paths, and SwiftPM rejects the package graph with
`invalid custom path 'Sources/TailscaleKit'` — an error that names TailscaleKit
even when you're building something that doesn't depend on it, because the
whole graph is loaded before anything compiles. If you've already cloned
without it, `scripts/materialize-symlinks.sh` repairs a checkout in place.

## Why a separate package

`Apps/linux-gtk` carries `CGtkVideo`, a GTK-linked C target that cannot build
here, and pulls a GTK toolchain no Windows job should pay for. The split is the
same one that already exists between `Apps/linux` and `Apps/linux-gtk`.

The app depends on swift-cross-ui's `DefaultBackend` rather than naming
`WinUIBackend`, since swift-cross-ui already resolves the backend per platform.

swift-cross-ui is pinned to the same exact revision as the GTK app on purpose —
its `View` protocol is young and reshapes across versions, and two apps
disagreeing about it would be a needless source of drift.
