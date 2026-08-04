# tailscreen (Windows)

The native Windows desktop app — swift-cross-ui on WinUI, reusing the same
portable core as the macOS and Linux apps.

**A full sharer and viewer**, on x64 and arm64. It brings up a real tsnet node,
signs in through the browser, lists the tailnet's Tailscreen peers, dials one
into a viewing session with libavcodec video and WASAPI audio, and shares its
own screen back through the Windows.Graphics.Capture picker — with viewer
annotations and opt-in remote control.

| Piece | How | Where |
| :--- | :--- | :--- |
| Video decode | libavcodec → `WriteableBitmap` | `TailscreenVideoFFmpeg`, `I420Converter` |
| Audio out | WASAPI shared-mode, off the UI thread | `WASAPIKit`, `ThreadedAudioSink` |
| Capture + encode | WGC picker → BGRA→I420 → libavcodec | `WGCCaptureKit`, `TailscreenSharerWGC` |
| Remote control | `SendInput` | `SendInputKit` |
| Annotations | click-through layered window | `WinOverlayKit` |
| Chrome | swift-cross-ui on WinUI | `TailscreenHubUI`, shared with Linux |

Everything above those seams — admission, RTP fan-out, NACK/FEC, congestion
control, the grant gate — is the portable core in `Packages/TailscreenKit`,
identical to what macOS and Linux run. The stage-by-stage history lives in
`plans/viewer-windows-plan.md`.

**What has and hasn't been seen working.** CI proves the app builds, stages,
loads every DLL, brings a tsnet node up, and installs and launches from an
MSIX — on both architectures. It cannot prove a frame was drawn or a sample
heard: the runners have no sharer to dial, no display and no sound card. Real
hardware testing has started and is turning up cross-platform session bugs
(see the limits below), so treat this as working-but-young rather than proven.

**Startup has historically been flaky.** The same binary has both reached its
event loop and aborted at startup on consecutive CI runs, surfacing as
`0xC000001D` (illegal instruction, `ud2`) or `0xC0000409` (`__fastfail`) —
the two ways a Swift trap shows up on Windows, so neither is a signature worth
chasing. If the app quits instantly, run it again before investigating; if it
quits every time, that is a different problem and the log will say so.

A few lines about unimplemented swift-cross-ui WinUI entry points
(`setSizeLimits`, `setIncomingURLHandler`) are expected and harmless — gaps in
the backend, not faults here.

## Where the output goes

The executable is built for the **GUI subsystem**, so launching it does not
open a terminal. SwiftPM's default is a console-subsystem PE, which meant the
loader materialised a console window before any of our code ran — including for
the MSIX-installed app, where a stray terminal is simply wrong.

That would normally throw away every diagnostic this app prints, so
`ConsoleBridge` reattaches stdio on startup:

- launched **from a terminal** → attaches to that console and keeps printing
  there (output lands after the shell's prompt returns, the usual
  GUI-app-with-console interleaving, but it is all there);
- launched **any other way** → redirects stdout *and* stderr to
  `%LOCALAPPDATA%\Tailscreen\logs\tailscreen.log`, truncated per launch so the
  file is always "the last run".

For the MSIX-installed app, `%LOCALAPPDATA%` writes are virtualised, so the log
is under `%LOCALAPPDATA%\Packages\<family>\LocalCache\Local\Tailscreen\logs\`.

`freopen` reuses the stream's fd slot, so fd 2 stays fd 2 — which means the
Swift runtime's own fatal-error report follows the redirection into the log
rather than vanishing. **If the app dies on startup, that file is the first
place to look.**

## Testing it on a Windows machine

You do not need a Swift toolchain to try it. Every push that touches this app
builds it in the `Windows build` workflow and attaches the app together with
the Swift runtime it needs:

1. Open the latest **Windows build** run in the repository's Actions tab.
2. Download the **`tailscreen-windows-x64`** artifact.
3. Unzip it **keeping the folder intact**, and run `tailscreen.exe`
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

A window should appear with a status line reading **Not signed in** and a **Sign
in to Tailscale** button. Clicking it:

1. Creates a tsnet node under the active account's state directory —
   `%LOCALAPPDATA%\Tailscreen\tailscale` for the first account, which is the
   single fixed directory this app used before it had accounts, so upgrading
   keeps you signed in. Further accounts get
   `%LOCALAPPDATA%\Tailscreen\profiles\<uuid>`, and the registry itself is
   `%LOCALAPPDATA%\Tailscreen\profiles.json` (shared `AccountProfileStore`, see
   `Packages/TailscreenKit`). The header's account menu switches between them,
   adds one, and carries **Sign out**.
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
window and audio goes to the default output device. **Share my screen** goes the
other way, through the WGC picker.

### Known limits

- **Cross-platform sessions are the current rough edge.** Real-hardware testing
  has surfaced a Mac→Windows path that shows no video, and Windows→Mac
  annotations and remote control not surfacing on the far end. Being worked;
  Windows↔Windows and the CI-gated pieces are unaffected.
- Remote control and annotations require the capture item's screen rect to
  resolve. A WGC `GraphicsCaptureItem` carries no HMONITOR, so its size is
  matched against the enumerated monitors — a **window** capture, or two
  identical monitors, deliberately declines rather than guessing. When it
  declines, the viewer stops being offered both features, which is the intended
  failure but looks like a missing feature if you don't know why.
- Audio failure is silent by design: if the output device cannot be opened, or
  its shared-mode mix format is not 32-bit float, the session continues
  video-only and says so once in the log.
- Changing the default output device mid-session ends audio for that session.
  Reopening on the next buffer would fix it and wants a retry budget so a
  permanently absent device does not thrash; not done yet.
- The MSIX is **self-signed** with the repo's stable dev certificate, so it
  installs only after that certificate is trusted; the zip is plain
  unzip-and-run but unsigned, so SmartScreen warns on first launch. Proper
  signing (SignPath's free OSS tier) and winget submission are the next step.
- The window is fixed-size in practice: `setSizeLimits` is unimplemented in
  swift-cross-ui's WinUI backend.
- Startup has been intermittently flaky — see above.

## Building it yourself

Needs the [swift.org Windows toolchain](https://www.swift.org/install/windows/)
(**6.3** is what CI uses on both architectures) and the Windows App SDK that
swift-cross-ui's `WinUIBackend` targets.

On arm64 the toolchain pairing is not free: Go's cgo passes MinGW flags like
`-mthreads` that Swift's MSVC-targeting clang rejects, so the libtailscale
c-archive is built with **llvm-mingw**'s aarch64 driver while Swift compiles
the Swift. `.github/actions/bootstrap` owns that, so you get it for free in CI
and need it only if you build the archive by hand.

Installing the toolchain also puts the runtime DLLs on PATH, which is the other
way to run a bare `tailscreen.exe` if you have one lying around without
its folder.

```powershell
swift build --package-path Apps\windows --product tailscreen
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

`Apps/linux` carries `CGtkVideo`, a GTK-linked C target that cannot build here,
and pulls a GTK toolchain no Windows job should pay for. The split is the same
one that already exists between `Packages/TailscreenLinuxBackends` and
`Apps/linux`.

The Windows-only *backends* are packages rather than targets in this app for a
sharper reason: `Packages/TailscreenSharerWGC`, `WinOverlayKit` and
`SendInputKit` carry **no WinUI**, which is what lets Linux CI typecheck them —
and `SendInputKit`'s decisions are unit-tested there through an inject-nothing
seam. That check costs seconds. A Windows runner costs ~25 minutes, and used to
be the first thing to notice a type error.

The app depends on swift-cross-ui's `DefaultBackend` rather than naming
`WinUIBackend`, since swift-cross-ui already resolves the backend per platform.

swift-cross-ui is pinned to the same exact revision as the GTK app on purpose —
its `View` protocol is young and reshapes across versions, and two apps
disagreeing about it would be a needless source of drift.
