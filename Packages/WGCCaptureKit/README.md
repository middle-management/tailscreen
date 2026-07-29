# WGCCaptureKit

Screen capture for the **Windows sharer**, via Windows.Graphics.Capture.

## Why WGC, and not DXGI Desktop Duplication

Duplication was written first and deleted. It is simpler — plain COM, no WinRT,
~250 lines — but it captures a whole display output and nothing else.

The macOS app's entire share flow is the picker: `SCContentSharingPicker` in a
helper process returns an `SCContentFilter`, `PickerSelection` carries
display / window / application, and there is deliberately no other entry point.
A Windows sharer built on Duplication could only ever answer
`PickerSelection.kind == .display`, and the app's share UI would then have been
shaped around a limitation the macOS app does not have.

WGC is the actual analogue:

| macOS | Windows |
|---|---|
| `SCContentSharingPicker` | `GraphicsCapturePicker` |
| `SCContentFilter` | `GraphicsCaptureItem` |
| display / window / app | display / window |

## Raw WinRT ABI, not C++/WinRT

cppwinrt leans on MSVC's standard library, and MSVC's STL hard-asserts a
compiler version the Swift toolchain's clang does not satisfy — WASAPIKit hit
this as `error STL1000: Unexpected compiler version, expected Clang 20 or
newer`. So the shim calls the ABI interfaces directly: `RoGetActivationFactory`,
`RoActivateInstance`, vtable calls, manual `HSTRING`s.

C++ is still required, for **`__uuidof`**: it reads each IID out of the SDK
header's own annotation rather than a hand-copied GUID, and a hand-copied GUID
fails at run time with `E_NOINTERFACE`, which no CI job can catch.

## Two things that are polled rather than subscribed

**The picker.** `PickSingleItemAsync` returns an `IAsyncOperation`. Rather than
implement a completion handler as a COM object in raw ABI, the shim polls
`IAsyncInfo::get_Status` while pumping messages. The picker is modal system UI
and needs a pump regardless; a hand-written handler's failure mode is a silent
hang, which is the worst one available.

**Frames.** `TryGetNextFrame` is non-blocking, so the timeout is the shim's to
implement, and `FrameArrived` would be another COM object for no benefit — the
caller wants a pull API.

`withFrame` returns `nil` when nothing arrived in time, and that is the normal
state of a still target: WGC produces a frame only when the content changes. The
caller re-encodes what it has rather than treating it as failure.

## No prerequisite

WinRT, D3D11 and DXGI ship with Windows. The package links `runtimeobject`,
`d3d11`, `dxgi` and `ole32`. `WGC.isSupported` checks
`GraphicsCaptureSession.IsSupported` before any UI is shown, so a machine
without WGC (pre-1803, or policy-disabled) gets a sentence rather than a failed
share.

## What it deliberately does not do

**No I420 conversion.** `BGRAToI420` in `TailscreenProtocol` converts, where
Linux CI round-trips it against the viewer's inverse — the only check that
catches a colour-range mistake, since those never fail loudly and simply wash
out every frame.

**No stride assumption.** The row pitch is the driver's and is routinely wider
than `width * 4`; reading at `width * 4` skews the image further with every row.

**No app exclusion.** macOS's Cloaked Apps rides `SCContentFilter`'s
`excludingApplications:`. Windows has no capturer-side equivalent —
`WDA_EXCLUDEFROMCAPTURE` is set by the *owner* of a window, not by whoever is
capturing it — so that feature has no Windows counterpart under either API.

## `wgc-probe`

Exists first to make the **linker** run: a SwiftPM library target is compiled
but never linked, which is how WASAPIKit's GUID mistake passed its own CI step
and surfaced eleven minutes later in the app. This shim has more unresolved
symbols than any other here — four import libraries plus every activation
factory — so the check is worth more.

Also worth running on a desktop: it shows the picker, then prints the chosen
target's name, size and a green-channel spread over a sparse grid. A real
desktop is never uniform, so a non-zero spread is the same evidence
`scripts/e2e-linux-sharer.sh` asserts on — a frame *count* alone would accept a
flat rectangle.

## Not verified on hardware

Everything under `#ifdef _WIN32` has been compiled and linked but never run.
This is the largest blind write in the Windows port so far, which is why the
probe exists and why it is worth running before the sharer is wired to it.
