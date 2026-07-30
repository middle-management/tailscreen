import Foundation
import TailscreenViewer

/// A plain 16:9 gradient frame used only by `--ui-preview-video`, so the hub /
/// annotation overlay can be screenshotted over something video-shaped. The CI
/// render self-test deliberately keeps `makeColorBarsFrame()` — its pixel
/// assertions are calibrated to those bars.
func makePreviewFrame(width: Int, height: Int) -> DecodedVideoFrame {
    let cw = (width + 1) / 2
    let ch = (height + 1) / 2
    var y = [UInt8](repeating: 0, count: width * height)
    for row in 0..<height {
        let value = UInt8(40 + (row * 120) / max(1, height))
        for col in 0..<width { y[row * width + col] = value }
    }
    // Muted blue-grey so red/green annotation strokes stay legible on top.
    let u = [UInt8](repeating: 140, count: cw * ch)
    let v = [UInt8](repeating: 118, count: cw * ch)
    return DecodedVideoFrame(width: width, height: height, yPlane: y, uPlane: u, vPlane: v)
}
