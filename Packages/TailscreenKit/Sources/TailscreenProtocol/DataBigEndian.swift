import Foundation

/// The module's one set of big-endian `Data` helpers — every wire codec in
/// TailscreenProtocol (RTP + UDP control, the framed TCP channel, the
/// capture-helper pipe) writes multi-byte fields network-order, and three
/// files had grown identical `fileprivate` copies of these before they were
/// promoted here.
///
/// Internal on purpose: the helpers are an implementation detail of the
/// codecs, not wire API — the pinned bytes are the codecs' outputs, covered
/// by `RTPPacketTests` / `ScreenShareProtocolTests` / `CaptureHelperWireTests`
/// and the wire registry. (Being `internal`, they also stop at the module
/// boundary: other modules — e.g. `TailscreenSharer`'s in-place header
/// rewrite — keep their own bytes.)
///
/// The `read` variants trust the caller for bounds, exactly as the inlined
/// shifts they replaced did: every call site sits behind a length check.
/// Indexes are `Data.Index`-relative (`self.index(_:offsetBy:)`), so slices
/// with non-zero `startIndex` read correctly.
extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBE(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    func readBE(_: UInt16.Type, at index: Data.Index) -> UInt16 {
        let b0 = UInt16(self[index])
        let b1 = UInt16(self[self.index(index, offsetBy: 1)])
        return (b0 << 8) | b1
    }

    func readBE(_: UInt32.Type, at index: Data.Index) -> UInt32 {
        let b0 = UInt32(self[index])
        let b1 = UInt32(self[self.index(index, offsetBy: 1)])
        let b2 = UInt32(self[self.index(index, offsetBy: 2)])
        let b3 = UInt32(self[self.index(index, offsetBy: 3)])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    func readBE(_: UInt64.Type, at index: Data.Index) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0..<8 {
            value = (value << 8) | UInt64(self[self.index(index, offsetBy: offset)])
        }
        return value
    }
}
