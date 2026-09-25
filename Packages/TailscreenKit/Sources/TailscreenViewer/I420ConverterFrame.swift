import TailscreenProtocol

/// The frame-shaped face of `I420Converter` (whose arithmetic lives in
/// `TailscreenProtocol` since both the viewer's CPU blit and the sharer's
/// preview thumbnail need it, but only this side has a `DecodedVideoFrame`).
extension I420Converter {
    /// Converts `frame` into `destination`, which must have room for
    /// `width × height × 4` bytes.
    ///
    /// Returns `false` without writing anything if the frame's planes are
    /// smaller than its declared dimensions, so a truncated frame shows the
    /// previous picture rather than garbage.
    @discardableResult
    public static func convert(
        _ frame: DecodedVideoFrame,
        into destination: UnsafeMutablePointer<UInt8>
    ) -> Bool {
        convert(
            Source(
                yPlane: frame.yPlane, uPlane: frame.uPlane, vPlane: frame.vPlane,
                width: frame.width, height: frame.height, range: frame.colorInfo.range),
            into: destination)
    }
}
