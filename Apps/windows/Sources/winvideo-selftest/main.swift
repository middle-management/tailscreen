// Headless render self-test for the Windows viewer's D3D11 shader.
//
// The counterpart of the GTK app's `tailscreen --render-self-test`, and a
// separate executable for the same reason `tsnet-probe` is one: it is a CI
// diagnostic, not a shipped app. Being separate is what makes it useful here —
// it links `CWinVideo` and nothing from WinUI, so it needs no XAML, no window,
// no desktop session and no package identity. `winvideo_selftest_check` renders
// to an offscreen target and reads the pixels back.
//
// It needs no GPU either: `winvideo_init` tries `D3D_DRIVER_TYPE_HARDWARE` and
// falls back to `D3D_DRIVER_TYPE_WARP`, Microsoft's software rasteriser, which
// implements the same D3D11 feature levels. So a GPU-less runner exercises the
// real shader — the Windows equivalent of Xvfb plus software GL on Linux, and
// there is nothing to configure to get it.
//
// Exit codes are the GTK self-test's, so a CI step reads the same way on both
// platforms: 0 pass, 3 render mismatch, 2 no D3D11 device at all (a distinct and
// more actionable failure than a wrong pixel).

#if os(Windows)

import CWinVideo
import Foundation
import TailscreenViewer

// The SAME frame the GL self-test asserts against — that is the point of it
// living in TailscreenViewer rather than beside either renderer. A disagreement
// between the two platforms now means the two shaders disagree about BT.709,
// not that they were fed different pixels.
let frame = makeColorBarsFrame()

guard winvideo_init() != 0 else {
    // `print` rather than a write to `FileHandle.standardError`: the latter is
    // ordinary Foundation and probably fine, but `print` + `exit` is the pair
    // every existing Windows probe in this repo already proves on CI, and the
    // authoritative WINVIDEO_SELFTEST markers come from C on stderr anyway.
    print("WINVIDEO_SELFTEST result=NODEVICE")
    exit(2)
}

let ok = frame.yPlane.withUnsafeBufferPointer { y in
    frame.uPlane.withUnsafeBufferPointer { u in
        frame.vPlane.withUnsafeBufferPointer { v in
            winvideo_selftest_check(
                Int32(frame.width), Int32(frame.height),
                y.baseAddress, u.baseAddress, v.baseAddress)
        }
    }
}

winvideo_reset()
exit(ok == 1 ? 0 : 3)

#else

import Foundation

// Present so the file typechecks wherever the package does. Nothing to test off
// Windows: `CWinVideo` is a `.when(platforms: [.windows])` dependency and its
// implementation is compiled to nothing by its own `#if defined(_WIN32)`.
print("WINVIDEO_SELFTEST result=SKIPPED (not Windows)")
exit(0)

#endif
