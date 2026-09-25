/// A 256×64 I420 test frame of four vertical bars, with YUV values chosen so a
/// BT.709 shader yields unambiguous colours.
///
/// Shared so the GTK (`tailscreen --render-self-test`, GL/Xvfb) and Windows
/// (`winvideo-selftest`, D3D11/WARP) render self-tests assert against the
/// same frame — a disagreement then means the shaders disagree, not that one
/// test frame is wrong.
///
/// Bars are named white/black/red/blue by intent; only 0 and 1 are exact:
///
/// | bar | Y, U, V       | BT.709 result   |
/// |-----|---------------|-----------------|
/// | 0   | 235, 128, 128 | rgb(255,255,255)|
/// | 1   |  16, 128, 128 | rgb(0,0,0)      |
/// | 2   | 128, 128, 255 | rgb(255,63,130) |
/// | 3   | 128, 255, 128 | rgb(130,103,255)|
///
/// Bars 2/3 are mid-luma max-chroma, not saturated red/blue — self-tests
/// MUST use relative predicates (`r > 180 && r > b + 60`), never exact values
/// with a tolerance (an exact-value check failed a correct render by 47 on
/// green here before).
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
