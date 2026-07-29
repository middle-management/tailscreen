# DXGICaptureKit

Screen capture for the **Windows sharer**, via DXGI Desktop Duplication.

## Why a local package

The sharer data plane (`TailscreenSharer`) is portable — viewer admission, RTP
fan-out, NACK/FEC, congestion control, the idle sweep — and needs exactly two
things from a platform: something that captures and encodes, and something that
injects input. This is the capture half of the first, and the counterpart of
`X11CaptureKit` on Linux and ScreenCaptureKit on macOS.

## Why Desktop Duplication, not Windows.Graphics.Capture

WGC is the modern API and can capture a single window, which Duplication cannot.
It is also WinRT: it needs a `GraphicsCaptureItem`, which normally comes from a
system picker, and on older Windows builds it draws a yellow capture border the
app cannot disable.

Duplication is plain COM, captures a whole output, and has no UI. That matches
what the Linux sharer already does — `X11CaptureEncoder` captures a root window
and rejects per-window shares rather than silently sharing the whole screen —
so both platforms land on the same honest limitation behind the same seam.
Per-window capture is a later change on both, and WGC is the right answer here
when it comes.

## No prerequisite

D3D11 and DXGI ship with Windows; their headers are in the Swift toolchain's
`Windows.sdk`. The package links `d3d11` and `dxgi` and nothing else.

## Shape

```swift
import DXGICaptureKit

let capture = try DXGI.ScreenCapture(outputIndex: 0)
capture.width, capture.height

let bytes = try capture.withFrame(timeoutMilliseconds: 100) { frame in
    // frame.bgra, frame.stride — valid ONLY inside this closure
    frame.stride * frame.height
}
```

`withFrame` returns `nil` when no frame arrived in time, and that is the normal
state of a still screen: Duplication produces a frame only when the desktop
actually changes. The caller re-encodes what it already has rather than treating
it as a failure — which is also why the encoder keeps running at the requested
frame rate over a static desktop.

The frame is unmapped before `withFrame` returns, whether the closure throws or
not. Escaping the pointer is a use-after-unmap; the scoped shape exists to make
that hard to do by accident.

## What it deliberately does not do

**No I420 conversion.** X11CaptureKit does its own in C; this hands back BGRA
and a row pitch, and `BGRAToI420` in `TailscreenProtocol` converts. That is
where Linux CI can round-trip it against the viewer's inverse converter, which
is the only check that catches a colour-range mistake — those never fail loudly,
they just wash out every frame.

**No stride assumption.** The row pitch is the driver's and is routinely wider
than `width * 4`. Reading at `width * 4` skews the image further with every row,
so the pitch is carried through to the converter rather than derived.

## `dxgi-probe`

An executable that exists first to make the **linker** run over the COM shim: a
SwiftPM library target is compiled but never linked, which is exactly how
WASAPIKit's GUID mistake passed its own CI step and surfaced eleven minutes
later in the app's link.

Unlike `wasapi-probe` it is also worth running on a real desktop. It prints the
captured geometry and a cheap green-channel spread across a sparse grid, so
"capture works" can be checked without standing up a share. A real desktop is
never uniform, so a non-zero spread is the same evidence
`scripts/e2e-linux-sharer.sh` asserts on the Linux side — a frame *count* alone
would happily accept a flat rectangle.

```
dxgi-probe: duplication open — 2560×1440
dxgi-probe: frame 1: stride 10240, green 17…255
```

## Not verified on hardware

Everything under `#ifdef _WIN32` has been compiled and linked but never run
against a real display. The package builds on Linux and macOS too, resolving to
an empty module, so the manifest and the wrapper's non-Windows syntax are
checked by every job rather than only the Windows one.
