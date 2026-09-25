import Foundation

/// How a decoded frame's luma and chroma samples use their 8-bit code space.
///
/// Not cosmetic: applying one range's maths to the other's samples crushes
/// blacks/clips highlights, or washes blacks to grey, on every frame with
/// nothing saying why. Sharers disagree by construction — `BGRAToI420` (and
/// its C twin in `X11CaptureKit`) produce **limited** range, while macOS
/// capture is **full** range by default (dropping to limited only for
/// 10-bit, since ScreenCaptureKit vends no full-range 10-bit format). So
/// this rides with the frame rather than being a constant per renderer.
public enum VideoColorRange: String, Sendable, Equatable, CaseIterable {
    /// "Video range": luma 16–235, chroma 128±112. The default a decoder must
    /// assume when the bitstream says nothing (H.264/HEVC
    /// `video_full_range_flag` absent or 0).
    case limited
    /// Luma 0–255, chroma 128±127.
    case full

    /// Short technical label for the stats overlays. Deliberately not
    /// localized, like the codec and colour-primary names beside it.
    public var shortLabel: String { self == .full ? "full" : "limited" }
}

/// Colour primaries as far as anything portable needs to distinguish them.
/// Deliberately coarse: exists to be *displayed*, not to round-trip every
/// H.273 registry value. Unrecognised values land in `other` and render as
/// their raw code, more honest than silently reporting BT.709.
public enum VideoColorPrimaries: Sendable, Equatable {
    case unspecified
    case bt709
    case bt601
    case displayP3
    case bt2020
    case other(Int)

    /// Short technical label for the stats overlays. Not localized — these are
    /// standards names, and translating "BT.709" would make it harder to read,
    /// not easier.
    public var shortLabel: String {
        switch self {
        case .unspecified: return "—"
        case .bt709: return "BT.709"
        case .bt601: return "BT.601"
        case .displayP3: return "P3"
        case .bt2020: return "BT.2020"
        case .other(let code): return "code \(code)"
        }
    }
}

/// Transfer characteristics, at the same coarseness and for the same reason as
/// `VideoColorPrimaries`.
public enum VideoTransferFunction: Sendable, Equatable {
    case unspecified
    case bt709
    case srgb
    case pq
    case hlg
    case other(Int)

    /// Short technical label for the stats overlays; not localized.
    public var shortLabel: String {
        switch self {
        case .unspecified: return "—"
        case .bt709: return "BT.709"
        case .srgb: return "sRGB"
        case .pq: return "PQ"
        case .hlg: return "HLG"
        case .other(let code): return "code \(code)"
        }
    }
}

/// What a decoder learned about a frame's colour encoding, carried alongside
/// the samples.
///
/// `range` is the load-bearing field — the renderers read it to pick their
/// YUV→RGB maths. `primaries` and `transfer` are carried for the stats
/// overlays: a viewer that can *see* "BT.709 · limited" can tell a colour
/// complaint from a colour bug, which reading the code cannot.
public struct VideoColorInfo: Sendable, Equatable {
    public var range: VideoColorRange
    public var primaries: VideoColorPrimaries
    public var transfer: VideoTransferFunction

    public init(
        range: VideoColorRange = .limited,
        primaries: VideoColorPrimaries = .unspecified,
        transfer: VideoTransferFunction = .unspecified
    ) {
        self.range = range
        self.primaries = primaries
        self.transfer = transfer
    }

    /// What a frame carries when nothing said otherwise: limited-range (what
    /// the codec specs mandate for an absent `video_full_range_flag`), with
    /// primaries/transfer left honestly unstated rather than assumed BT.709.
    public static let unspecifiedLimited = VideoColorInfo()

    /// One line for a stats overlay: `"BT.709 · limited"`, or just the range
    /// when the primaries are unstated (printing "— · limited" would be
    /// noise). Not localized; see `VideoColorRange.shortLabel`.
    public var shortLabel: String {
        var parts: [String] = []
        if primaries != .unspecified { parts.append(primaries.shortLabel) }
        if transfer != .unspecified, transfer != .bt709 { parts.append(transfer.shortLabel) }
        parts.append(range.shortLabel)
        return parts.joined(separator: " · ")
    }
}
