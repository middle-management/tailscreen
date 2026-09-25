import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox

/// Color characteristics of the captured/encoded video: primaries, transfer
/// function, YCbCr matrix, bit depth, and full/limited range — carried
/// alongside the pixel data so capture, encode, and render agree.
///
/// **Never crosses the wire.** VideoToolbox writes it into the SPS VUI
/// in-band, and the viewer reads it back off the decoded buffer's
/// attachments. `ColorInfo` is only the sharer side's source of truth for
/// tagging `SCStreamConfiguration`/the encoder; the viewer derives its
/// `CAMetalLayer.colorspace` independently (`MetalViewerRenderer.layerColorSpaceName`).
///
/// Mapping helpers here are pure, so `ColorInfoTests` pin them without a GPU,
/// display, or tsnet node.
struct ColorInfo: Codable, Equatable, Sendable {
    /// `bt709` is SDR default; `displayP3` wide-gamut; `bt2020` HDR container.
    enum Primaries: String, Codable, Sendable {
        case bt709
        case displayP3
        case bt2020
    }

    /// `pq` = SMPTE ST 2084, `hlg` = ITU-R BT.2100 HLG.
    enum Transfer: String, Codable, Sendable {
        case bt709
        case pq
        case hlg
    }

    enum Matrix: String, Codable, Sendable {
        case bt709
        case bt2020
    }

    var primaries: Primaries
    var transfer: Transfer
    var matrix: Matrix
    /// Luma bit depth: 8 for Main / High, 10 for HEVC Main 10.
    var bitDepth: Int
    /// Must stay consistent capture->encode->decode or near-black/near-white
    /// crush returns.
    var fullRange: Bool

    static let bt709FullRange8 = ColorInfo(
        primaries: .bt709, transfer: .bt709, matrix: .bt709, bitDepth: 8, fullRange: true)

    /// HDR-capable + 10-bit displays get BT.2020 PQ; wide-gamut displays get
    /// Display P3 in a 709 transfer; everything else stays BT.709.
    static func forDisplay(wideGamut: Bool, hdrCapable: Bool, bitDepth: Int) -> ColorInfo {
        var info = bt709FullRange8
        info.bitDepth = bitDepth
        // ScreenCaptureKit's 10-bit capture is video-range only ('x420') — no
        // full-range 10-bit format exists — so 10-bit must be video-range
        // end-to-end.
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

    /// Used by the Main10 -> 8-bit fallback ladder; keeps Display P3 primaries
    /// but drops any HDR transfer/matrix back to 709.
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
    /// H.264 always uses High — this pipeline never emits 10-bit H.264.
    func profileLevel(for codec: VideoCodec) -> CFString {
        switch codec {
        case .hevc:
            return bitDepth >= 10 ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        case .h264:
            return kVTProfileLevel_H264_High_AutoLevel
        }
    }

    var capturePixelFormat: OSType {
        switch (bitDepth >= 10, fullRange) {
        case (true, true): return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case (true, false): return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (false, true): return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case (false, false): return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    }

    /// `nil` leaves SCStream at its default (BT.709 path untouched).
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
    /// Maps a decoded buffer's `kCVImageBufferColorPrimariesKey` attachment to
    /// the `CAMetalLayer` colorspace name; falls back to sRGB.
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

    /// Short stats-overlay label, e.g. `"P3 · PQ"`, `"BT.709"`, or nil.
    ///
    /// Deliberately omits RANGE: the mac decoder asks VideoToolbox for 32BGRA
    /// output, so by render time the buffer is RGB and no YCbCr range exists
    /// to print. The portable viewers report range from libavcodec instead.
    static func statsLabel(primaries: String?, transfer: String?) -> String? {
        var parts: [String] = []
        if let primaries {
            if primaries == (kCVImageBufferColorPrimaries_P3_D65 as String) {
                parts.append("P3")
            } else if primaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String) {
                parts.append("BT.2020")
            } else if primaries == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String) {
                parts.append("BT.709")
            }
        }
        if let transfer {
            if transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) {
                parts.append("PQ")
            } else if transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
                parts.append("HLG")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
