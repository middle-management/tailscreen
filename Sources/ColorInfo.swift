import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox

/// Color characteristics of the captured/encoded video: primaries, transfer
/// function, YCbCr matrix, bit depth, and full/limited range. Carried
/// alongside the pixel data so capture, encode, and render agree instead of
/// each hardcoding a BT.709 8-bit triple.
///
/// **Correctness never depends on `ColorInfo` crossing the wire.** VideoToolbox
/// writes primaries/transfer/matrix + bit depth into the HEVC/H.264 SPS VUI,
/// which already rides the in-band parameter-set path, and the viewer's
/// `CMVideoFormatDescriptionCreateFrom…ParameterSets` reads them straight back
/// onto the decoded `CVPixelBuffer`'s attachments. `ColorInfo` is the *sharer*
/// side's single source of truth: the capture-helper computes it from the
/// display it's capturing, tags the `SCStreamConfiguration` and the encoder
/// from it, and the viewer's renderer derives its `CAMetalLayer.colorspace`
/// from the decoded buffer's attachments (see
/// `MetalViewerRenderer.layerColorSpaceName`).
///
/// The mapping helpers to VideoToolbox CFString keys and `CGColorSpace` names
/// live here and are pure, so `ColorInfoTests` can pin them on CI without a
/// GPU, display, or tsnet node.
struct ColorInfo: Codable, Equatable, Sendable {
    /// Color primaries. `bt709` is the shipped default; `displayP3` covers
    /// wide-gamut Macs; `bt2020` is the HDR container.
    enum Primaries: String, Codable, Sendable {
        case bt709
        case displayP3
        case bt2020
    }

    /// Transfer function (EOTF). `bt709` is SDR; `pq` (SMPTE ST 2084) and
    /// `hlg` (ITU-R BT.2100 HLG) are the two static-HDR curves.
    enum Transfer: String, Codable, Sendable {
        case bt709
        case pq
        case hlg
    }

    /// YCbCr → RGB matrix. `bt709` for SDR/P3; `bt2020` for HDR.
    enum Matrix: String, Codable, Sendable {
        case bt709
        case bt2020
    }

    var primaries: Primaries
    var transfer: Transfer
    var matrix: Matrix
    /// Luma bit depth: 8 for Main / High, 10 for HEVC Main 10.
    var bitDepth: Int
    /// Full-range (JPEG) vs limited-range (studio) luma/chroma. The shipped
    /// capture path is full-range NV12 (`ScreenCapture`), so this defaults
    /// true; it must stay consistent capture→encode→decode or near-black /
    /// near-white crush returns.
    var fullRange: Bool

    /// The shipped default: BT.709 primaries/transfer/matrix, 8-bit,
    /// full-range. Bit-for-bit the pre-`ColorInfo` hardcodes (VideoEncoder's
    /// 709 triple + ScreenCapture's full-range `420f`), so passing this as
    /// the parameter default preserves existing behavior exactly.
    static let bt709FullRange8 = ColorInfo(
        primaries: .bt709, transfer: .bt709, matrix: .bt709, bitDepth: 8, fullRange: true)

    /// Pick the capture/encode color space for a display's capabilities.
    /// HDR-capable + 10-bit displays get BT.2020 PQ at 10-bit; wide-gamut
    /// displays get Display P3 in a 709 transfer (the standard "P3 in a 709
    /// container" screen-content choice) at the requested depth; everything
    /// else stays BT.709 — the shipped behavior. Pure and CI-tested.
    static func forDisplay(wideGamut: Bool, hdrCapable: Bool, bitDepth: Int) -> ColorInfo {
        var info = bt709FullRange8
        info.bitDepth = bitDepth
        // ScreenCaptureKit's deep-color (10-bit) capture is the *video-range*
        // biplanar format ('x420'); the full-range 10-bit format SCStream does
        // not vend, so a 10-bit share must be video-range end-to-end (the
        // encoder's range tag then follows this `fullRange`). 8-bit stays
        // full-range (the shipped default is unchanged).
        if bitDepth >= 10 {
            info.fullRange = false
        }
        if hdrCapable && bitDepth >= 10 {
            info.primaries = .bt2020
            info.transfer = .pq
            info.matrix = .bt2020
        } else if wideGamut {
            info.primaries = .displayP3
        }
        return info
    }

    /// SDR 8-bit version of this info, keeping the primaries when they're
    /// Display P3 (still worth tagging at 8-bit) but dropping any HDR
    /// transfer/matrix back to 709. Used by the Main10 → 8-bit fallback ladder
    /// so a viewer that can't decode 10-bit still gets correct colors. Pure.
    func downgradedTo8Bit() -> ColorInfo {
        var info = self
        info.bitDepth = 8
        info.transfer = .bt709
        info.matrix = .bt709
        if info.primaries == .bt2020 {
            info.primaries = .bt709
        }
        return info
    }
}

// MARK: - VideoToolbox key mappings (encoder side)

extension ColorInfo.Primaries {
    /// `kVTCompressionPropertyKey_ColorPrimaries` value.
    var vtKey: CFString {
        switch self {
        case .bt709: return kCVImageBufferColorPrimaries_ITU_R_709_2
        case .displayP3: return kCVImageBufferColorPrimaries_P3_D65
        case .bt2020: return kCVImageBufferColorPrimaries_ITU_R_2020
        }
    }
}

extension ColorInfo.Transfer {
    /// `kVTCompressionPropertyKey_TransferFunction` value.
    var vtKey: CFString {
        switch self {
        case .bt709: return kCVImageBufferTransferFunction_ITU_R_709_2
        case .pq: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .hlg: return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        }
    }
}

extension ColorInfo.Matrix {
    /// `kVTCompressionPropertyKey_YCbCrMatrix` value.
    var vtKey: CFString {
        switch self {
        case .bt709: return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case .bt2020: return kCVImageBufferYCbCrMatrix_ITU_R_2020
        }
    }
}

extension ColorInfo {
    /// HEVC/H.264 profile level for this codec at this bit depth. 10-bit HEVC
    /// needs Main 10; 8-bit HEVC uses Main; H.264 always uses High (this
    /// pipeline never emits 10-bit H.264). Pure and CI-tested.
    func profileLevel(for codec: VideoCodec) -> CFString {
        switch codec {
        case .hevc:
            return bitDepth >= 10 ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        case .h264:
            return kVTProfileLevel_H264_High_AutoLevel
        }
    }

    /// Biplanar 4:2:0 capture pixel format for this bit depth: 10-bit picks
    /// `x420` (full) / `x422`-style deep-color, 8-bit stays `420f`. Full vs
    /// limited range follows `fullRange`. Pure and CI-tested.
    var capturePixelFormat: OSType {
        switch (bitDepth >= 10, fullRange) {
        case (true, true): return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case (true, false): return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (false, true): return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case (false, false): return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    }

    /// `SCStreamConfiguration.colorSpaceName` to request, or `nil` to leave
    /// SCStream at its default. We only override for non-709 spaces
    /// (wide-gamut / HDR) so the shipped BT.709 capture path is untouched.
    var captureColorSpaceName: CFString? {
        switch (primaries, transfer) {
        case (.bt2020, .pq): return CGColorSpace.itur_2100_PQ
        case (.bt2020, .hlg): return CGColorSpace.itur_2100_HLG
        case (.displayP3, _): return CGColorSpace.displayP3
        default: return nil
        }
    }
}

// MARK: - Renderer-side colorspace derivation

extension ColorInfo {
    /// Map a `kCVImageBufferColorPrimariesKey` attachment string (as read off
    /// a decoded `CVPixelBuffer`) to the `CGColorSpace` name the viewer's
    /// `CAMetalLayer` should be tagged with. Falls back to sRGB — the shipped
    /// default — for BT.709 or anything unrecognized. Pure and CI-tested.
    static func layerColorSpaceName(forPrimaries primaries: String?) -> CFString {
        guard let primaries else { return CGColorSpace.sRGB }
        if primaries == (kCVImageBufferColorPrimaries_P3_D65 as String) {
            return CGColorSpace.displayP3
        }
        if primaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String) {
            return CGColorSpace.itur_2020
        }
        return CGColorSpace.sRGB
    }
}
