import TailscreenProtocol

/// The frame-shaped face of `I420Converter`.
///
/// The arithmetic lives in `TailscreenProtocol`, because it has two callers on
/// opposite sides of the app — the viewer's CPU blit and the sharer's preview
/// thumbnail — and only one of them has a `DecodedVideoFrame`. This overload is
/// what keeps the viewer's call sites reading the way they always did.
extension I420Converter {
    /// Convert `frame` into `destination`, which must have room for
    /// `width × height × 4` bytes.
    ///
    /// Returns `false` without writing anything if the frame's planes are
    /// smaller than its declared dimensions — a truncated frame should show the
    /// previous picture rather than garbage or a crash, and a decoder that
    /// emits one is broken in a way the renderer cannot paper over.
    @discardableResult
    public static func convert(
        _ frame: DecodedVideoFrame,
        into destination: UnsafeMutablePointer<UInt8>
    ) -> Bool {
        convert(
            yPlane: frame.yPlane, uPlane: frame.uPlane, vPlane: frame.vPlane,
            width: frame.width, height: frame.height, into: destination)
    }
}
