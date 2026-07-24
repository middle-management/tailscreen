import TailscreenViewer

/// A 256×64 I420 test frame of four vertical bars — white, black, red, blue —
/// with YUV values chosen so a BT.709 shader yields unambiguous colours. Used
/// by the render self-test (`--render-self-test`) and as a placeholder frame.
public func makeColorBarsFrame() -> DecodedVideoFrame {
    let w = 256, h = 64, cw = w / 2, ch = h / 2
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
