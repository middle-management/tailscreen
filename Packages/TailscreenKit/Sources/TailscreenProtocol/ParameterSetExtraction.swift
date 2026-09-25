import Foundation

/// Picks the codec parameter sets out of a keyframe's NAL units.
///
/// Shared by every `CaptureEncoding` backend that encodes with libavcodec
/// (X11, Windows), which otherwise each hand-roll the same bit-mask table
/// and risk disagreeing. Lives here rather than in FFmpegKit: pure byte
/// arithmetic with no libavcodec dependency, so `linux-protocol` can test it
/// without libavcodec installed, and it returns ``CodecParameterSets``, a
/// type FFmpegKit can't name.
///
/// Takes Annex-B NALs, already split by the caller (`NALUnit.avccToAnnexB`
/// then `NALUnit.annexBNALs`).
public enum ParameterSetExtraction {
    /// H.264 NAL types, from the low five bits of the header byte.
    private enum H264: UInt8 {
        case sps = 7
        case pps = 8
    }

    /// HEVC NAL types, from bits 1–6 of the header byte.
    ///
    /// The field moved AND widened vs H.264 — `& 0x1F` on an HEVC NAL reads a
    /// wrong number rather than absent, so a mixed-up mask fails silently
    /// (no parameter sets, black viewer, fine sharer preview).
    private enum HEVC: UInt8 {
        case vps = 32
        case sps = 33
        case pps = 34
    }

    /// - Parameters:
    ///   - nals: Annex-B NAL units with start codes already stripped.
    ///   - codec: which mask/type table to read them with.
    /// - Returns: the parameter sets, or `nil` if any required one is absent.
    ///
    /// All-or-nothing: a viewer needs the complete set to build a decoder,
    /// so a partial one only moves the failure later. On duplicates the
    /// FIRST wins.
    public static func parameterSets(
        fromAnnexBNALs nals: [Data],
        codec: VideoCodec
    ) -> CodecParameterSets? {
        switch codec {
        case .h264:
            let byType = index(nals) { $0 & 0x1F }
            guard let sps = byType[H264.sps.rawValue], let pps = byType[H264.pps.rawValue] else {
                return nil
            }
            return .h264(sps: sps, pps: pps)
        case .hevc:
            let byType = index(nals) { ($0 >> 1) & 0x3F }
            guard let vps = byType[HEVC.vps.rawValue],
                let sps = byType[HEVC.sps.rawValue],
                let pps = byType[HEVC.pps.rawValue]
            else { return nil }
            return .hevc(vps: vps, sps: sps, pps: pps)
        }
    }

    /// Type → first NAL of that type. Empty NALs are skipped rather than
    /// indexed under a guessed type.
    private static func index(
        _ nals: [Data],
        type: (UInt8) -> UInt8
    ) -> [UInt8: Data] {
        Dictionary(
            nals.compactMap { nal -> (UInt8, Data)? in
                guard let first = nal.first else { return nil }
                return (type(first), nal)
            },
            uniquingKeysWith: { first, _ in first })
    }
}
