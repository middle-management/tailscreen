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
builds it in the `Windows build` workflow and attaches the executable:

1. Open the latest **Windows build** run in the repository's Actions tab.
2. Download the **`tailscreen-windows`** artifact.
3. Unzip and run `tailscreen-windows.exe`.

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
(6.0.3 is what CI uses) and the Windows App SDK that swift-cross-ui's
`WinUIBackend` targets.

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
