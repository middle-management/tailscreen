---
title: Windows app on swift-cross-ui / WinUI
nav_order: 13
permalink: /viewer-windows-plan/
---

# Bringing Tailscreen to Windows (swift-cross-ui / WinUI)

This is **L5** of the [Linux GTK viewer plan](/linux-viewer-gtk-plan/): the same
native-feeling desktop app on **Windows**, reusing everything the Linux effort
proved. It is a porting plan, not an implementation — except for one spike
(below), which exists because the plan's original toolchain claim turned out to
be wrong.

> **Correction.** An earlier version of this document said the native-dependency
> work was "build `libtailscale.a` for Windows — add a `windows/amd64` target".
> That is not true, and it understated the single largest item by a wide margin.
> The measurement is in [the blocker](#the-real-blocker-libtailscales-gonative-bridge).

## Two distances, not one

The port splits into two very different jobs, and conflating them is what made
the original estimate wrong:

- **A Windows viewer** is close. There is even a route that sidesteps the
  blocker entirely (see [the escape route](#the-escape-route-and-its-ceiling)).
- **A Windows sharer** is not, because it needs inbound tailnet listeners —
  exactly what the broken bridge provides.

## Why most of it is already done

The hard, novel work was Linux (L0–L4, plus the sharer extraction), and almost
all of it is backend-agnostic Swift that already compiles for Windows unchanged:

| Layer | Status | Windows change |
|---|---|---|
| Receive data plane — `ViewerSession` (NACK/RR/PLI/FEC) | portable, CI-tested | none |
| Send data plane — `TailscaleScreenShareServer` (admission, fan-out, congestion, fairness) | portable | none |
| Video decode — `FFmpegVideoDecoder` | portable Swift | link Windows FFmpeg (libav*) |
| Video encode — `FFmpeg.VideoEncoder` | portable Swift | same |
| tsnet transport — `TsnetTransport` | portable Swift | **see the blocker** |
| Back-channel — `ViewerBackChannel` | portable Swift | none |
| Picker — `PickerModel` + `discoverPeers` | portable Swift | none |
| Chrome — `ViewerUIState`, `ViewerControls`, the swift-cross-ui view tree | portable Swift | none |
| Frame hand-off — `FrameStore` | portable Swift | none |
| Off-thread audio — `ThreadedAudioSink` | was Linux-only | ✅ moved to the portable tier, reused unchanged |
| Audio out — `ALSAAudioSink` | Linux-only | ✅ **new:** `WASAPIKit` + `WASAPIAudioSink` |
| Video surface — `GtkVideoView` + `CGtkVideo` | Linux-only | ✅ **new:** `WinUIVideoView` (`Image` + `WriteableBitmap`; `SwapChainPanel` later) |
| Capture — `X11CaptureKit` + `X11CaptureEncoder` | Linux-only | **new:** DXGI Desktop Duplication behind `CaptureEncoding` |
| Input injection | none on Linux | **new:** `SendInput` + HID→VK |

The Linux platform leaves came to roughly **2,300 lines total**, which is the
right yardstick for the Windows ones:

| Leaf | Linux size |
|---|---|
| `X11CaptureKit` (capture) | 413 |
| `X11CaptureEncoder` (`CaptureEncoding` conformance) | 335 |
| `CGtkVideo` (GPU video surface) | 441 |
| `ALSAKit` (audio out) | 143 |
| `TailscreenViewerGtk` (view + glue) | 992 |

## The UI risk is smaller than it looks

The original plan named one load-bearing spike: *can a downstream `View` conform
to the public protocol, downcast the generic backend to the concrete one, and
return a native widget as `Backend.Widget` — no `@_spi`, no fork?* That is the
shape `GtkVideoView` uses today.

On Windows the trick isn't needed. swift-cross-ui's `WinUIBackend` ships
**`WinUIElementRepresentable`** — a public, documented `NSViewRepresentable`
analogue returning any `WinUI.FrameworkElement`, which `SwapChainPanel` is. The
backend is also comparably built out: 3,643 lines against `GtkBackend`'s 2,813.

So the video surface is a first-class integration, not an escape hatch. What
remains genuinely new is the D3D11 side: upload Y/U/V as three
`DXGI_FORMAT_R8_UNORM` textures, draw a fullscreen triangle with the **same
BT.709 matrix** as `cgtkvideo.c`'s fragment shader, aspect-fit with the same
`uXform` constants, `Present`. Zoom/pan and context-loss recovery map 1:1
(`cgtkvideo_reset` ↔ `DXGI_ERROR_DEVICE_REMOVED`). A C/C++ shim keeps Swift free
of COM/D3D boilerplate exactly as `CGtkVideo` keeps it free of GL.

## The real blocker: libtailscale's Go↔native bridge

Go itself is not the problem. It accepts `-buildmode=c-archive` for
`windows/amd64` and resolves the whole Windows Tailscale dependency set (wintun,
wingoes, certstore, go-winio). `tailscale.c` includes `<sys/socket.h>` and
`<unistd.h>` but never uses them — cosmetic.

`tailscale.go` is the problem. Its entire Go↔native handoff rests on:

- **`syscall.Socketpair(AF_LOCAL, …)`** — undefined for `GOOS=windows`.
- **`syscall.Sendmsg` + `syscall.UnixRights`** — SCM_RIGHTS descriptor passing,
  for which Windows has no equivalent at all.
- **`golang.org/x/sys/unix`** — Unix-only by construction.

19 call sites across 828 lines. Windows has AF_UNIX *stream* sockets since Win10
1803, but no `socketpair()` and **no AF_UNIX datagram mode** — and our own
`Patches/013-add-tsnet-listen-packet-go.patch`, the UDP path carrying all video,
uses a `SOCK_DGRAM` socketpair.

### A trap that would cost a day

Several Winsock wrappers in Go's `syscall` package **compile on Windows but are
`EWINDOWS` stubs that always fail at runtime**: `Accept`, `Recvfrom`, `Sendto`,
`SetsockoptTimeval`. `Socket`, `Bind`, `Listen`, `Connect`, `Getsockname`,
`Closesocket`, `WSARecv`, `WSASend` are real. Code written against the
compiler's opinion alone builds cleanly and fails on first use.

### The spike

`spikes/windows-tsnet-bridge/` retired this risk before any UI work, with no
tsnet involved so a failure pointed at the primitive rather than at forty layers
of Tailscale. It built loopback replacements for both socketpair flavours and
proved, on a real Windows runner:

- stream round trip in both directions;
- **datagram boundaries preserved** — one datagram in, exactly one out, which is
  what patch 013 depends on and what a stream socket would silently break;
- the native handle fits in a C `int` (a `SOCKET` is `UINT_PTR`, 64-bit on
  win/amd64, while `tailscale_conn` is `int`);
- the accept handoff works **without SCM_RIGHTS** — Go and native code share one
  process and therefore one handle table, so the handle *value* suffices. The
  Unix machinery exists for a constraint we do not have;
- a Go-side close surfaces to the native end as EOF.

Leg B repeated the stream and datagram checks from real C `recv()` across a cgo
c-archive boundary, because that is where linkage and runtime-init surprises
live.

**The spike and its `windows-spike` workflow have since been deleted.** They
answered their question and patch 024 shipped the answer; the `Windows build`
job now builds the real c-archive, links it into the app and runs `tsnet-probe`
against it, which is strictly stronger evidence than the spike could give. The
findings above are the record — the code was scaffolding, not the record.

Note the replacement is *simpler* than the Unix original: the accept side uses
Go's `net` package (avoiding the `Accept` stub), which makes the Go end an
idiomatic poller-managed `net.Conn` rather than raw `syscall.Read` on a
dedicated OS thread — the Unix code carries a TODO asking for exactly that.

### Knock-on: the Swift wrapper

`TailscaleKit`'s Swift side `read`/`write`s the descriptor. On Windows those must
become `recv`/`send` — the CRT's `_read`/`_write` do not work on sockets. Patch
022 already established the pattern for platform gates.

## The escape route, and its ceiling

`tailscale_loopback()` is already in the C API, and tsnet's SOCKS5 server
supports **both `connect` and `udpAssociate`** with a real bidirectional UDP
relay. So a Windows **viewer** could use ordinary Winsock sockets to
`127.0.0.1` and never touch the bridge at all.

Two caveats, both to be measured rather than assumed:

1. Every video datagram takes an extra userspace hop through the Go relay. At
   60fps that cost is real and currently unknown.
2. SOCKS5 gives outbound dial. The **sharer** needs inbound listeners on 7447
   (TCP and UDP), and tsnet's SOCKS5 implements no `BIND`. This route reaches a
   viewer and stops.

## Toolchain, build, CI

- **Swift on Windows** (swift.org toolchain) + the **Windows App SDK** that
  `WinUIBackend` / `CWinAppSDK` target.
- **FFmpeg** libav* via vcpkg or prebuilt shared libs; **libopus** likewise.
- **libtailscale** per the blocker above — a patch series, not a build flag.
- A new SwiftPM package `Apps/windows`, sibling to `Apps/linux-gtk`, reusing
  `TailscreenViewerCore` / `TailscreenViewerTsnet` and TailscreenKit's portable
  tiers. `FrameStore` already moved into `TailscreenViewer`; `ViewerUIState`,
  `ViewerControls` and `PickerModel` should follow into a backend-neutral target
  so neither app drags in the other's UI framework.
- **CI:** a `windows-viewer` job on `windows-latest` — build, then a headless D3D
  render self-test on the **WARP** software rasterizer (`D3D_DRIVER_TYPE_WARP`),
  the moral equivalent of the Linux job's Mesa `llvmpipe`, reading back the four
  colour-bar centres and the letterbox pixel like `cgtkvideo_selftest_check`. If
  WARP read-back proves flaky headless, degrade to a compile gate plus a
  documented local render check, and say so rather than pretend around it.

## Phasing

Numbering here now matches the commits, the READMEs and the app's own doc
comments. An earlier revision of this file numbered the stages differently
(video at W2, audio at W4), which stopped being true once the bridge work split
into W1/W1b and the UI landed before the transport.

- **W0 — bridge spike.** ✅ Green on a Windows runner, then deleted once patch
  024 shipped the real bridge. *The one that could have invalidated the shape;
  it came first.*
- **W1 — the bridge for real.** ✅ Patch 024: `bridge.go` seam,
  `bridge_windows.go` on loopback TCP/UDP pairs.
- **W1b — the Swift wrapper.** ✅ Patch 025: `recv`/`send`/`closesocket`,
  `WSAPoll`, and `WSAGetLastError` in place of `errno`.
- **W2 — the app renders.** ✅ swift-cross-ui on WinUI, portable tiers reachable
  from the UI. Confirmed by eye on a real Windows 11 desktop.
- **W3 — the app reaches the tailnet.** ✅ `lld-link` links the 56 MB Go
  c-archive; the app signs in (browser login off the IPN bus) and lists tailnet
  peers. Transport moved to `TailscreenViewerTsnet` in TailscreenKit so Windows
  consumes it without FFmpeg/ALSA/X11. *Live sign-in against a real tailnet is
  the outstanding manual check.*
- **W4 — video.** ✅ `FFmpegVideoDecoder` behind the portable `VideoDecoding`
  seam, blitted into a WinUI `Image`/`WriteableBitmap`. The decoder moved to
  `Packages/TailscreenVideoFFmpeg` so consuming it doesn't also drag in ALSA and
  X11; the colour conversion is `I420Converter` in the portable tier, tested on
  Linux. *No frame has been watched — CI has no sharer and no display.*
- **W5 — audio.** ✅ WASAPI shared-mode rendering behind the portable
  `AudioSink` seam (`Packages/WASAPIKit`), the counterpart to ALSAKit on Linux,
  fronted by `ThreadedAudioSink` so the blocking device write stays off the
  WinUI main thread. `ThreadedAudioSink` moved from `Apps/linux` into the
  portable tier — it was always thread + queue over `AudioSink` — and the
  48 kHz mono → device-format adaptation is `MonoPCMConverter`, also portable
  and tested. *No sound has been heard.*
- **W6 — sharer.** ✅ **Windows.Graphics.Capture, not DXGI Desktop
  Duplication** — this entry used to say DXGI, and that was the wrong call.
  Duplication only ever yields a whole output; WGC has a picker and a per-window
  model, which is what actually matches macOS's `SCContentSharingPicker`, and
  sharing one window is the common case. `TailscreenSharerWGC` behind
  `CaptureEncoding`, `SendInputKit` behind `InputInjecting`, `WinOverlayKit` for
  annotations. *No real screen has been captured — CI has no display.*
- **W7 — the silently-broken parts.** ✅ Per-monitor-v2 DPI awareness (without
  it both remote control and annotations resolve to nothing, with no error);
  the overlay's owned message-pump thread; annotations advertised as a
  capability rather than assumed; the hub chrome extracted to
  `Packages/TailscreenHubUI` and shared with the GTK app; the Windows app
  typechecked on Linux CI.
- **W8 — packaging.** ← next. Installer, signing, distribution channels. See
  below; nothing here is decided yet.

### W4 in detail

The two halves are independent and can fail independently, so they are separate
steps rather than one "video" push.

**Decode.** Reuse `FFmpegVideoDecoder` — the same `VideoDecoding` conformance the
Linux viewer runs, already exercised against our exact RTP path by
`PipelineIntegrationTests`. Media Foundation would give hardware decode and drop
~100 MB of DLLs from the artifact, but it is a from-scratch COM backend with no
reuse, so it is an optimisation for later rather than the way in.

Two things must happen first:

1. *Gate it.* `windows-build.yml`'s `ffmpeg` job fetches a pinned LGPL shared
   FFmpeg 7.1 and runs FFmpegKit's suite on Windows. If libavcodec cannot link
   here, the decision above is void and W4 becomes Media Foundation.
2. *Extract it.* The decoder currently sits in `Apps/linux`'s
   `TailscreenViewerCore` beside the ALSA sink, so consuming it drags in
   ALSAKit and X11CaptureKit as package dependencies — the same coupling that
   kept the transport unusable on Windows until W3 moved it. It needs its own
   package depending only on FFmpegKit + TailscreenViewer.

**Licensing is not a footnote here.** Tailscreen is MIT. A GPL FFmpeg build
(the ones carrying libx264) would impose GPL on the whole app if shipped. The
viewer only ever decodes, so an LGPL build is both sufficient and the only
correct choice — and it is what CI now tests against.

**Render.** `WinUIElementRepresentable` is a full `NSViewRepresentable`
analogue (`associatedtype WinUIElementType: WinUI.FrameworkElement`, with
make/update/coordinator/sizeThatFits), so any `FrameworkElement` can host the
video. The hand-off from the decode side already exists and is portable:
`FrameStore` in `TailscreenViewer` is described as "the lock + value-type-COW
frame hand-off any renderer backend polls from its UI thread", which is exactly
what an `updateWinUIElement` tick wants.

Start with `Image` + `WriteableBitmap` and a CPU I420→BGRA conversion. It is
slow and it is correct, and it makes "pixels on screen" a small debuggable
increment. `SwapChainPanel` + D3D11 is the performance answer and can replace it
without touching the decoder, the session, or `FrameStore` — which is the point
of having the seam.

### W8 in detail — packaging

Today the artifact is a staged directory: the exe, an explicit list of Swift
runtime DLLs, the FFmpeg LGPL DLLs, libopus, and the Windows App SDK
bootstrapper at the one literal relative path `swift-winui` looks for. That is
fine for CI and not something to hand a user.

Four decisions, and they are close to independent — the ordering below is by
what unblocks what, not by importance.

**1. Stop needing the bootstrapper.** WinUI 3 resolves its framework dependency
one of two ways: through the package graph (MSIX), or through the bootstrapper
API (unpackaged), which needs the Windows App SDK runtime installed or carried
alongside. The staging bugs this cost us — the bootstrapper at the wrong path,
then an arm64 bootstrapper beside an x64 exe — were both this mechanism. Windows
App SDK **self-contained mode** bundles the runtime and deletes the lookup
entirely. It is the smallest change here, it is independent of every other
decision, and it removes a whole bug class rather than adding an assertion
against it. Do this first regardless of what else is chosen.

**2. Signing, which is the long pole.** Since June 2023 OV/EV code signing
private keys must live on FIPS 140-2 hardware, so **a `.pfx` in CI secrets is no
longer possible for a newly issued certificate** — the pattern the macOS release
workflow uses does not transfer. The options are a cloud signing service (Azure
Trusted Signing, DigiCert KeyLocker, SSL.com eSigner), a hardware token on a
self-hosted runner, or **SignPath**, which has a free tier for OSS projects and
a GitHub Actions integration. SignPath is the obvious first call for an MIT
project; Certum's OSS-priced hardware certs are the usual alternative.

*Check Azure Trusted Signing's eligibility rules before planning around it —
Microsoft has changed who can onboard more than once, and this note may be out
of date by the time you read it.*

Unsigned is not a neutral choice: SmartScreen warns on download and first run,
which lands badly for an app that then asks for screen capture and input
injection. This has the longest lead time of anything in W8, so start it early
even if the installer format is undecided.

**3. Installer format.**

- **MSIX** — Microsoft's modern format and WinUI 3's native story. Clean
  install/uninstall, differential updates, Store-eligible, and it makes decision
  1 moot by resolving the framework dependency through the package graph. Costs:
  the manifest `Publisher` must match the signing cert's subject exactly, a
  self-signed cert means users hand-installing it, and the container's
  virtualized filesystem/registry occasionally surprises apps that write beside
  their exe (we don't — tsnet state is in AppData).
- **Inno Setup** — what most OSS desktop projects actually ship. One
  self-contained exe, handles shortcuts/uninstall/upgrade-in-place without
  ceremony. Unglamorous, hard to beat at our size.
- **WiX / MSI** — the enterprise answer: Group Policy deployment, admin
  transforms, per-machine installs. WiX v4 is a ground-up rewrite from v3, so
  v3-era material misleads. Heaviest to author; worth it only if someone asks
  for managed deployment.
- **Velopack** — successor to Squirrel.Windows. Its distinguishing feature is
  auto-update with delta packages. Premature until there is a release cadence to
  update along.

**4. Distribution channels, which are layered on top and not alternatives to
the above.** All three want the same thing: a stable download URL and a
checksum. None of them changes the format decision, which is why they come last
and are individually cheap.

- **winget** — ships with Windows 11 (via App Installer), which is the whole
  argument. Declarative YAML manifest submitted to `microsoft/winget-pkgs`
  pointing at an installer plus hashes; accepts MSI, MSIX or plain exe. Highest
  leverage per unit of effort for a developer-facing tool.
- **Scoop** — developer-focused, installs per-user with no admin rights, JSON
  manifests in git "buckets". The cheapest to publish, because **you can host
  your own bucket** — a repo with a manifest in it — with no review queue at
  all. Good fit for the audience most likely to install a Tailscale-adjacent
  tool early.
- **Chocolatey** — predates winget (2011) and still has the deepest catalogue
  and the strongest sysadmin/ops following. Packages are NuGet `.nupkg`
  containers wrapping **PowerShell install scripts**, which is the real
  difference from winget's declarative manifests: a Chocolatey package can do
  arbitrary work — dependency chains, custom logic, papering over a badly
  behaved installer — where a winget manifest essentially points at one. That
  power is also its cost: it's a script to maintain per release, the community
  repository has a moderation queue that adds latency to a release, and the
  `AU` PowerShell module exists specifically because keeping package versions
  current by hand doesn't scale. At 142 MB the package should download from
  GitHub Releases with a checksum rather than embed the binary — which is what
  Chocolatey's own guidelines want anyway.

  **Verdict for us: winget first, Scoop second, Chocolatey if asked for.** Its
  audience skews toward automated fleet provisioning, which is not where a
  peer-to-peer screen-sharing GUI finds its first users. Revisit if anyone asks
  to deploy Tailscreen across an estate.

#### W8b — what the MSIX probe has actually established

**Packing and signing work.** MakeAppx packs the `app` job's staged directory —
the exe plus its Swift runtime, FFmpeg, libopus and WindowsAppSDK DLLs, plus a
templated `AppxManifest.xml` and logo assets — into a **142.4 MB** `.msix`, and
SignTool signs it. The package is uploaded as `tailscreen-windows-msix` on every
run, so it can be inspected by hand.

Two design choices in `scripts/windows/make-msix.ps1` that are worth keeping:

- The manifest's `Publisher` is **derived from the signing certificate's
  Subject**, read back off the created cert rather than assumed to equal the
  requested string — `New-SelfSignedCertificate` normalises spacing, and a
  publisher mismatch fails at *install* time naming neither side.
- `ProcessorArchitecture` is read from the **exe's PE header**, not passed in.
  An architecture mismatch inside a package fails on the user's machine, not in
  CI.

**Install and activation work. The packaged app does not stay running.** Four of
the five stages pass:

| Stage | Result |
|---|---|
| MakeAppx pack | ✅ `Package creation succeeded`, 142.4 MB |
| SignTool sign | ✅ |
| Trust cert + `Add-AppxPackage` | ✅ installed as `Tailscreen.Tailscreen_0.0.1.0_x64__0gj03dk66ap0y`, arch `X64` |
| Activate by AUMID | ✅ `activated, pid 6336` |
| Stay alive 12 s | ❌ **gone within 12 s** |

This is precisely the failure the job was built to detect, and it is worth being
clear about why it is informative rather than disappointing: **the same binary,
unpackaged, passes the `Check the app loads` step in the `app` job.** The only
difference is package identity. So this isolates the problem to packaged-mode
framework resolution rather than to the app, the staging, or the payload.

**The exit code is `0xC000001D`, `STATUS_ILLEGAL_INSTRUCTION`** — and it reframes
the failure rather than confirming the first guess.

It is **not** `0xC0000135`, so nothing is missing from the payload. `ud2`
(`0xC000001D`) and `__fastfail` (`0xC0000409`) are both how a Swift `fatalError`
/ failed precondition / nil force-unwrap reaches the OS, which means **the loader
was satisfied — every DLL in the package resolved — and then our own code decided
to die.** For a WinUI app the usual cause is swift-winui's
`SwiftApplication.main` turning a failed Windows App SDK init into `fatalError`.

So the framework-resolution hypothesis survives, but arriving as a Swift trap
rather than a loader error: a packaged process has no `<PackageDependency>` on
the WindowsAppRuntime framework, and swift-winui initialises through the
**unpackaged bootstrapper** regardless of identity, so it has neither route to
the runtime and traps.

**But a headless runner cannot decide this, and pretending otherwise was a bug in
this job.** The app job's unpackaged `Check the app loads` step reached that
conclusion first and already tolerates both trap codes with a warning, because a
WinUI app with no interactive desktop session may legitimately trap during
backend init and the runner cannot tell that apart from a real defect. This job
failing on the same codes was an unjustified asymmetry between the packaged and
unpackaged checks — the packaged path was being held to a standard the unpackaged
path had already been shown unable to meet.

`verify-msix.ps1` now matches that standard: loader- and install-level failures
stay fatal, because those *are* packaging bugs and the runner *can* decide them;
a Swift trap is reported with a warning naming both candidates, and the launch
verdict is explicitly deferred to a human on a real desktop. The classified exit
code is printed either way, which is how this was diagnosed at all.

**Net for W8b, then:** MSIX packing, signing, installation and activation are
proven in CI, and the `msix` job is now a **required gate** rather than
exploratory — `continue-on-error` removed. What it gates is deliberately narrow:
pack, sign, install, activate and any loader-level exit are fatal, because those
are packaging defects a headless runner can decide; a Swift trap after activation
is warned. **A red `msix` job therefore means the package is broken, not that the
app failed to launch.**

The packaged launch outcome is **not decidable in CI** and joins the existing
list of things needing a real Windows desktop — alongside "no frame has been
displayed", "no sound has been heard", and the DPI fix on a scaled display.

A caution for whoever runs it: `0xC000001D` is also one of the two codes in the
pre-existing **intermittent startup flakiness** of the *unpackaged* app
(`0xC000001D` / `0xC0000409`, cause unknown, documented as retry-first). Two
packaged runs both trapped where the unpackaged app traps only sometimes, which
is suggestive of a real packaged-mode difference — but two samples is not
evidence, and the codes are indistinguishable. Do not assume a packaged trap on a
real desktop is the framework issue without checking whether the unpackaged build
on that same machine is behaving.

**This corrects decision ordering earlier in this section.** W8's four decisions
were described as "close to independent". They are not. **MSIX cannot work until
the Windows App SDK deployment mode is settled** — either self-contained, or a
declared framework dependency with that framework present on the target machine.
Self-contained was already recommended first on the grounds that it deletes the
bootstrapper-path bug class; this makes it a **prerequisite** for the packaging
decision rather than merely a good idea, and it is the reason to do it before
choosing a format at all.

An earlier version of this section also implied MSIX would make the
architecture-mismatch class of bug "unrepresentable". That remains true of the
*payload* — the package records its own architecture and `Add-AppxPackage`
enforces it, which this run demonstrates by reporting `X64` — but it does not
help with framework resolution, which is a different mechanism entirely.

That is the **fourth** PowerShell-semantics bug in this workflow's history,
after the three integer-comparison ones in the load check (`[uint32]` on a
negative `Int32`, `-band 0xFFFFFFFF` not rescuing it, and `-eq 0xC0000135`
always false). The pattern is consistent enough to state as a rule: **in
PowerShell, assume the language's defaults are against you and assert the
behaviour you want.** Tolerating a native command's failure means clearing its
exit code as well as skipping the throw, and the script now also ends with an
explicit `exit 0` so this cannot recur silently.

So the question the job exists to answer — does a *packaged* WinUI 3 app resolve
its Windows App SDK dependency through the package graph, given swift-winui
initialises through the unpackaged bootstrapper either way — remains open. The
machinery to answer it is in place and the packaging half of it is done.

**And then the fix for that bug was itself unverified for the same reason the
WASAPIKit one was.** The commit repairing the exit code touched
`scripts/windows/make-msix.ps1` and one `.md`. The workflow's `!**/*.md`
negation removed the doc, and the script matched no pattern in the trigger at
all — `scripts/` was covered only by the single literal
`scripts/materialize-symlinks.sh`. **No Windows runner started.** The branch
looked fine and the fix sat unverified; it was found only by going to read a run
that did not exist.

The trigger now includes `packaging/windows/**` and `scripts/windows/**`, but the
more useful correction is to the *rule*. It was written as "if a package is in
the app's dependency graph, it belongs in both the trigger and the cache key",
and that phrasing is precisely what let the hole recur: these are not packages
and are in no dependency graph. Restated in the workflow as **"if a file is an
input to any job in this workflow, it belongs in this list"** — packages,
scripts, manifests, assets — with the cache key considered separately, since it
only cares about the subset that changes what gets compiled.

Three occurrences now (`WASAPIKit/**`, `TailscaleKit/**` + `OpusKit/**`, and
this one), so it is worth naming the general hazard rather than the instances: a
path-scoped workflow fails **silently and green**. A red build tells you
something is wrong; a run that never starts tells you nothing while the thing it
guards goes untested, and the absence is indistinguishable from success.

**LGPL constraint on all of the above.** The FFmpeg DLLs are LGPL shared builds,
deliberately — the GPL builds carry libx264 and would infect this MIT codebase.
Whatever the installer does, they must stay separately replaceable DLLs and the
package must carry the LGPL text and the relink offer. Any format here handles
that; the thing to avoid is a single-file bundler helpfully merging them in.

#### W8a — what the arm64 probe has actually established

Run natively on a `windows-11-arm` runner (GA for public repos, 4 vCPU, free),
so none of this is cross-compilation.

**Confirmed:**

- **Swift has a real Windows arm64 toolchain** and `SwiftyLab/setup-swift`
  resolves it: `swift-6.1.3-RELEASE-windows10-arm64`. Published since 6.0.
- **Go builds the patched libtailscale c-archive for `windows/arm64`** —
  55,378,236 bytes, with the full patch series including `bridge_windows.go`
  applied. The bridge needed no arm64-specific work: loopback TCP/UDP pairs and
  a handle value carry over unchanged.
- **FFmpeg has a supply route.** BtbN publishes
  `ffmpeg-n7.1-latest-winarm64-lgpl-shared-7.1.zip`, identical naming to the
  `win64` asset already consumed, so the video path needs a URL change and not a
  from-source build.
- **`CGoRuntimeInit` already handles arm64** — `#elif defined(_M_ARM64)` →
  `_rt0_arm64_windows_lib`, with a hard `#error` for an unrecognised
  architecture. Patch 026 anticipated this.

**The one real blocker found, and it is not ours:** cgo picks its C compiler
implicitly — `gcc` on PATH unless `CC` says otherwise — and the arm64 runner
image carries an **x86_64** gcc. It duly used it, and the build died inside
`runtime/cgo`:

```
gcc_arm64.S:30: Error: no such instruction: `stp x29,x30,[sp,'
```

`stp` is an ARM64 instruction, so that message is an x86 assembler reading ARM64
assembly. Nothing in it names a compiler, which is the whole argument for
answering this in a three-minute probe rather than inside a forty-minute app
build. The job now inventories every C compiler it can find, prints each one's
`-dumpmachine`, and chooses on that evidence. On this image **clang natively
targets arm64**, so no `--target` is needed and `CGO_TARGET_FLAGS` comes back
empty — the explicit-target path is retained as a fallback for images where it
would not.

Swift setup therefore runs **before** Go in that job, opposite to the app job,
because the Swift toolchain is where that clang comes from.

**The blocker is a two-sided toolchain bind, and it is why this is parked.**
Measured over three runs:

| | cgo / c-archive | `WinSDK` Swift module |
|---|---|---|
| Swift 6.1.3 | **works** (55 MB archive) | **broken** |
| Swift 6.3.3 | **broken** (`-mthreads`) | never reached |

On 6.3.3 the failure is earlier and more fundamental than a version quirk:

```
clang: error: unsupported option '-mthreads' for target 'aarch64-unknown-windows-msvc'
```

**Go's cgo assumes a MinGW-flavoured driver on Windows** and passes MinGW flags
like `-mthreads` unconditionally. Swift's clang targets windows-MSVC and rejects
them. 6.1.3's clang happened to *tolerate* the flag, which is why it got further
— not because it was the right compiler. Using Swift's clang for cgo was always
a workaround that happened to hold.

So the real fix is to stop conflating the two compilers: supply an **aarch64
llvm-mingw** toolchain for the c-archive and keep the MSVC toolchain for Swift.
**That fix is now wired into the probe** — and it is a return to parity, not a
novelty: the x64 job has always built the c-archive with the runner image's
MinGW gcc and let lld-link join the MinGW-ABI archive to MSVC-ABI Swift code.
The arm64 runner simply had no aarch64 MinGW, which is why the job wrongly
borrowed Swift's clang.

The probe installs llvm-mingw (pinned release, aarch64-hosted archive first with
x86_64-under-emulation as fallback, each candidate proven by running its
`-dumpmachine` before being trusted) and pairs it with **Swift 6.3**, because
each version's blocker is what the other half of the change addresses:
llvm-mingw takes cgo off Swift's clang entirely, so `-mthreads` stops mattering
and the Swift version only has to get the WinSDK module right — where 6.1.3
failed and 6.3.3 was never reached. If WinSDK still collides on 6.3 that is a
new data point, not a repeat.

The probe stays **on-demand** (`workflow_dispatch`, or the `run-arm64-probe`
label): four failures mean one reasoned attempt does not make it a gate.

On 6.1.3 the second side of the bind is:

```
winnt.h:6164:11: error: reference to '_ARM64_BARRIER_ISH' is ambiguous
  candidate ... swift-6.1.3-RELEASE-windows10-arm64/.../clang/include/arm64intr.h:23
<unknown>:0: error: could not build C module 'WinSDK'
```

The toolchain's own clang builtin header and the runner image's Windows SDK
(10.0.26100) both define that enumerator, so the `WinSDK` module map is
unbuildable with that pairing. **No workaround exists inside this repo** —
patch 025's POSIX shims import `WinSDK`, so the collision sits upstream of all
our code, not beside it.

This is the same shape as the documented 6.0.3 `could not build module 'ucrt'`
failure on x64: a toolchain/SDK mismatch. Moving the toolchain was the obvious
remedy and is what 6.3.3 was tried for — but it trades this failure for the
`-mthreads` one above, which is the bind. **The leg stays pinned to 6.1**, the
version that gets furthest, so whoever resumes starts from the furthest known
state rather than re-deriving it.

**Still unproven, therefore:** that `tsnet-probe` links on arm64, that
`tailscale_new()` returns, and everything above it (WinUI, FFmpeg, staging). What
IS established is that the two things expected to be hardest — the Go bridge and
the c-archive — are not the problem.

**Read this as a cost signal for W8.** Three distinct upstream failures inside
four runs of a probe that deliberately builds almost nothing: an x86_64 assembler
handed ARM64 assembly, a clang builtin header colliding with the Windows SDK, and
cgo's MinGW assumptions meeting an MSVC-targeting clang. None of them is our
code, and none has a fix that lives in this repo.

Multi-arch is therefore **not** a small increment on top of the x64 work, and a
dual-architecture MSIX should not be planned as though arm64 were a URL change
away — an earlier revision of this document implied exactly that, on the strength
of the Swift toolchain and FFmpeg assets existing. They do exist; they are not
the hard part. If arm64 matters it wants its own phase, and that phase starts
with llvm-mingw rather than with the app.

**Also unresolved, and cheap to forget:** no native arm64 build, so today's x64
artifact runs under emulation on ARM devices (which is how the W2/W3 manual
verification was done). Whether W8 ships a second architecture or an arm64
build lands separately is an open question, but the installer and the winget
manifest both grow a dimension when it does.

## Risks

- **Throughput.** The bridge adds a copy per datagram. Still unmeasured, and it
  matters more once video flows.
- **Startup flakiness.** The Windows app has both reached its event loop and
  aborted at startup from effectively identical binaries (`0xC000001D` /
  `0xC0000409`). One occurrence in three tsnet-linked CI runs so far. Cause
  unknown; if it clusters, chase it before W4 rather than during.
- **D3D device-lost.** Only once the renderer moves to `SwapChainPanel`: driver
  updates and sleep reset the GPU, so the shim must handle
  `DXGI_ERROR_DEVICE_REMOVED` by recreating device and swap chain. The CPU
  bitmap path has no such failure mode, which is a second reason to start there.
- **Headless render verification.** A CPU blit can be verified by reading back
  the bitmap, so unlike the D3D path it does not depend on WARP being
  deterministic.

## Threading (unchanged model)

Identical to the GTK app's proven model: the `@MainActor` transport Task runs
interleaved with the WinUI dispatcher loop; `present` → `FrameStore.set` stashes
the frame and requests a repaint marshalled to the UI thread. GTK is only ever
touched on its main thread and the same rule holds for WinUI. `FrameStore`'s
lock plus value-type COW copy already makes the cross-thread hand-off safe
regardless of backend.
