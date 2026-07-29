# tailscreen-windows

The native Windows desktop app — swift-cross-ui on WinUI, reusing the same
portable core as the macOS and Linux apps.

**Status: audio stage (W5).** The app brings up a real tsnet node, shows the
interactive browser-login URL, lists the tailnet's Tailscreen peers, and dials
one into a viewing session with libavcodec video and WASAPI audio. It cannot
share its own screen — that is W6 in `docs/viewer-windows-plan.md`.

What each stage established:

- **W2** — Swift, swift-cross-ui's WinUI backend and the portable tiers build
  and run together on Windows. Confirmed by eye on Windows 11 (2026-07-28):
  window renders, button responds, probe reads `arch x86_64 · fps cap 60 ·
  codec auto` out of `TailscreenProtocol`. That desktop was Windows-on-ARM, so
  the x64 binary ran under emulation and the probe reported it faithfully.
- **W3** — `libtailscale.a` (56 MB, `windows/amd64`) links into a Swift
  executable via `lld-link`, and the app starts and holds its event loop with
  tsnet linked in. Confirmed in CI, and the artifact has been downloaded and run
  unassisted on Windows 11. A live sign-in against a real tailnet is the
  remaining manual check.
- **W4** — video. `FFmpegVideoDecoder` (the Linux viewer's decoder, moved into
  `Packages/TailscreenVideoFFmpeg` so taking it does not also mean taking ALSA
  and X11) behind the portable `VideoDecoding` seam, blitted into a WinUI
  `Image` via a `WriteableBitmap`. The colour conversion is `I420Converter` in
  the portable tier, unit-tested on Linux. Compiles and links; no frame has been
  watched.
- **W5** — audio. WASAPI shared-mode rendering behind the portable `AudioSink`
  seam (`Packages/WASAPIKit`), fronted by `ThreadedAudioSink` so the blocking
  device write stays off the WinUI main thread. The 48 kHz mono → device-format
  conversion is `MonoPCMConverter` in the portable tier, also unit-tested on
  Linux. Compiles and links; no sound has been heard.

Several lines on stdout at startup are expected and harmless — gaps in
swift-cross-ui's WinUI backend, not faults here:

```
[WinUIBackend] setSizeLimits(ofWindow:minimum:maximum:) unimplemented
[WinUIBackend] setIncomingURLHandler(to:) not implemented
[WinUIBackend] failed to attach to parent console
```

**Startup is intermittently flaky.** The same binary has both reached its event
loop and aborted at startup on consecutive CI runs, with the abort surfacing as
`0xC000001D` or `0xC0000409`. It is not caused by linking tsnet — the trap
predates W3 and was seen from builds that differed only in a CI script. If the
app quits instantly, run it again before investigating; if it quits every time,
that is a different problem and the stderr text will say so.

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

A window should appear with a status line reading **Not signed in** and a **Sign
in to Tailscale** button. Clicking it:

1. Creates a tsnet node under `%LOCALAPPDATA%\Tailscreen\tailscale`.
2. Shows a login URL — as selectable text *and* an **Open in browser** button,
   because launching a browser is the step most likely to fail and a URL you can
   paste always works.
3. Once you complete the browser login, the status becomes **Signed in as
   \<you\>** and the tailnet's Tailscreen peers appear, each with an online dot,
   hostname and Tailscale IP.

**That peer list is the point of this stage.** A window can render without a
tailnet; a peer list cannot. If names you recognise appear there, libtailscale's
Windows bridge (patch 024) is carrying a real tsnet node — which is the claim
the whole port rests on.

An empty list is a *result*, not a failure, if the tailnet has no other
Tailscreen instance running: the app distinguishes "still looking" from "none
found" deliberately.

Clicking a peer dials it and starts a viewing session: the video fills the
window and audio goes to the default output device. Neither has been observed
working on real hardware yet — see the limits below.

### Known limits at this stage

- **Nobody has seen a frame or heard a sample.** Both paths compile, link and
  start; the decoder is covered by `linux-viewer`'s real encode→RTP→decode test
  and both conversions by unit tests, but CI has no sharer to dial and no
  display or sound card to check. This is the outstanding manual test.
- Audio failure is silent by design: if the output device cannot be opened, or
  its shared-mode mix format is not 32-bit float, the session continues
  video-only and says so once on stderr.
- Changing the default output device mid-session ends audio for that session.
  Reopening on the next buffer would fix it and wants a retry budget so a
  permanently absent device does not thrash; not done yet.
- It cannot share its own screen — W6.
- The node is brought up with `nodeRole: .viewerOnly`, so it is ephemeral and
  deliberately excluded from other peers' discovery. This machine can watch;
  it cannot yet be watched.
- x86_64 only. A native arm64 Windows build is unbuilt and untested; the x64
  binary does run under emulation on Windows-on-ARM, which is how the first
  confirmed run happened.
- Unsigned, so SmartScreen will warn on first run.
- The window is fixed-size in practice: `setSizeLimits` is unimplemented in
  swift-cross-ui's WinUI backend.
- Startup is intermittently flaky — see above.

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
