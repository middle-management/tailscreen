// Headless render self-test for the Windows viewer's D3D11 shader.
//
// The counterpart of the GTK app's `tailscreen --render-self-test`. A
// separate executable so it links `CWinVideo` and nothing from WinUI —
// no XAML, no window, no desktop session, no package identity.
// `winvideo_selftest_check` renders to an offscreen target and reads back.
//
// Needs no GPU either: `winvideo_init` falls back to `D3D_DRIVER_TYPE_WARP`
// (software rasteriser) when no hardware device exists.
//
// Exit codes match the GTK self-test's: 0 pass, 3 render mismatch, 2 no D3D11
// device at all.

#if os(Windows)

import CWinVideo
import Foundation
import TailscreenViewer

// The SAME frame the GL self-test asserts against, so a disagreement between
// platforms means the shaders disagree about BT.709, not that they were fed
// different pixels.
let frame = makeColorBarsFrame()

guard winvideo_init() != 0 else {
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

// Present so the file typechecks wherever the package does — nothing to test off Windows.
print("WINVIDEO_SELFTEST result=SKIPPED (not Windows)")
exit(0)

#endif
