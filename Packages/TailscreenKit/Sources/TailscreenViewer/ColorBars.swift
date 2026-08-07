/// A 256×64 I420 test frame of four vertical bars, with YUV values chosen so a
/// BT.709 shader yields unambiguous colours.
///
/// **In the portable tier because two platforms' render self-tests assert
/// against it**, and agreeing is the entire point: the GTK viewer renders it
/// through a GL shader under Xvfb (`tailscreen --render-self-test`) and the
/// Windows viewer renders it through a D3D11 shader under WARP
/// (`winvideo-selftest`). One frame, one set of expectations, so a disagreement
/// means the two shaders disagree about BT.709 rather than that one of them is
/// broken in isolation. It started out beside the GTK renderer and moved here
/// the moment Windows needed it — the same trip `FrameRateCounter` made.
///
/// The bars are named white / black / red / blue after their INTENT, and two of
/// those names are loose enough to have already misled once. Only the first two
/// are exact:
///
/// | bar | Y, U, V       | BT.709 result   |
/// |-----|---------------|-----------------|
/// | 0   | 235, 128, 128 | rgb(255,255,255)|
/// | 1   |  16, 128, 128 | rgb(0,0,0)      |
/// | 2   | 128, 128, 255 | rgb(255,63,130) |
/// | 3   | 128, 255, 128 | rgb(130,103,255)|
///
/// Bars 2 and 3 are mid-luma, maximum-chroma colours — NOT saturated red and
/// blue, which would be Y=63,Cr=240 and Y=32,Cb=240. So a self-test must assert
/// *relative* predicates (`r > 180 && r > b + 60`) and never exact values with a
/// tolerance: the first Windows attempt expected rgb(235,16,16) within ±24 and
/// would have failed a perfectly correct render by 47 on the green channel.
/// The predicates are still tight enough to catch what actually breaks — a
/// channel swap flips both inequalities.
public func makeColorBarsFrame() -> DecodedVideoFrame {
    let w = 256
    let h = 64
    let cw = w / 2
    let ch = h / 2
    let yb: [UInt8] = [235, 16, 128, 128]
    let ub: [UInt8] = [128, 128, 128, 255]
    let vb: [UInt8] = [128, 128, 255, 128]
    var y = [UInt8](repeating: 0, count: w * h)
    var u = [UInt8](repeating: 0, count: cw * ch)
    var v = [UInt8](repeating: 0, count: cw * ch)
    for row in 0..<h {
        for col in 0..<w { y[row * w + col] = yb[col / (w / 4)] }
    }
    for row in 0..<ch {
        for col in 0..<cw {
            let bar = (col * 2) / (w / 4)
            u[row * cw + col] = ub[bar]
            v[row * cw + col] = vb[bar]
        }
    }
    return DecodedVideoFrame(width: w, height: h, yPlane: y, uPlane: u, vPlane: v)
}
