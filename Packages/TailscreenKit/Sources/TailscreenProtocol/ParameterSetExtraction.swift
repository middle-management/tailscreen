import Foundation

/// Picks the codec parameter sets out of a keyframe's NAL units.
///
/// Every `CaptureEncoding` backend that encodes with libavcodec has to do
/// this: libavcodec hands back a keyframe with SPS/PPS (or VPS/SPS/PPS)
/// in-band, and the server wants them named. The X11 backend had it inline,
/// the Windows one needed the same thing, and a second hand-written copy of a
/// bit-mask table is how the two platforms quietly disagree.
///
/// It lives here — not next to the backends, and not in FFmpegKit — for two
/// reasons. It is pure arithmetic over bytes with no libavcodec in it, so
/// Linux CI's `linux-protocol` job runs its tests without libavcodec
/// installed. And it returns ``CodecParameterSets``, which FFmpegKit cannot
/// name.
///
/// **This takes Annex-B NALs, already split.** Splitting is the caller's
/// FFmpeg-side business (`NALUnit.avccToAnnexB` then `NALUnit.annexBNALs`);
/// what is worth sharing and worth testing is the part below — which byte
/// carries the type, how wide the field is, and which sets must all be
/// present for the answer to be usable.
public enum ParameterSetExtraction {
    /// H.264 NAL types, from the low five bits of the header byte.
    private enum H264: UInt8 {
        case sps = 7
        case pps = 8
    }

    /// HEVC NAL types, from bits 1–6 of the header byte.
    ///
    /// The field moved AND widened between the two codecs — `& 0x1F` on an
    /// HEVC NAL reads a number that is wrong rather than absent, so the two
    /// masks are not interchangeable and a mixed-up pair fails silently: no
    /// parameter sets, so viewers install nothing and see black while the
    /// sharer's own preview looks perfect.
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
    /// All-or-nothing on purpose. A viewer needs the complete set to build a
    /// decoder, so handing up a partial one would only move the failure later
    /// and further from its cause.
    ///
    /// On duplicates the FIRST wins. libavcodec emits one set per keyframe,
    /// but a backend that concatenates access units could present two, and
    /// "the first one in the frame" is at least a stated rule rather than
    /// whichever the dictionary happened to keep.
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
