import Foundation

/// Works out WHERE a Windows capture target is on screen, when the platform
/// won't say.
///
/// A WGC `GraphicsCaptureItem` is opaque: it has a size and a display name and
/// no HMONITOR or HWND. That is fine for capturing — the item is its own
/// handle — and fatal for remote control, which has to turn a viewer's
/// normalized `[0, 1]` coordinate into a screen pixel and therefore needs the
/// target's rect.
///
/// The only signal available is the item's size, matched against the
/// enumerated monitors. That works, with one important limit, and the limit is
/// what most of this type is about: **two monitors of the same resolution are
/// indistinguishable this way.** A dual 1920×1080 desk is not an exotic
/// configuration, so this case is common and must be handled, not hoped past.
///
/// The rule is therefore *unique match or nothing*. An ambiguous answer
/// returns `nil` and the host declines to offer remote control, because a
/// click landing on the wrong monitor is worse than a click that does not
/// happen — the viewer aimed at something they could see, and it went
/// somewhere they could not.
///
/// No Win32 here, so Linux CI runs the tests.
public enum WindowsCaptureRegion {
    /// Why a region could not be resolved. Surfaced to the sharer, because
    /// "Request Control is missing" with no explanation is a support ticket.
    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        /// The item's size matches no monitor — so it is a window, not a
        /// display. Window shares are not resolvable by size at all.
        case notADisplay
        /// Two or more monitors share this resolution, so which one the item
        /// refers to cannot be known.
        case ambiguousDisplays(count: Int)
        /// No monitors were reported, or the item reported no size.
        case unknownGeometry

        public var description: String {
            switch self {
            case .notADisplay:
                return "remote control needs a whole display; this is a window share"
            case .ambiguousDisplays(let count):
                return
                    "\(count) displays share this resolution, so remote control can't tell them apart"
            case .unknownGeometry:
                return "the display's position on screen is unknown"
            }
        }
    }

    /// Match a capture item's size against the monitors.
    ///
    /// - Parameters:
    ///   - itemWidth: the item's pixel width (`WGC.CaptureItem.size`).
    ///   - itemHeight: its pixel height.
    ///   - monitors: every monitor's bounds, in virtual-desktop coordinates.
    /// - Returns: the matching monitor's rect, or the reason there isn't one.
    public static func resolve(
        itemWidth: Int,
        itemHeight: Int,
        monitors: [WindowsPointerMapping.ScreenRect]
    ) -> Result<WindowsPointerMapping.ScreenRect, Failure> {
        guard itemWidth > 0, itemHeight > 0, !monitors.isEmpty else {
            return .failure(.unknownGeometry)
        }
        let matches = monitors.filter { $0.width == itemWidth && $0.height == itemHeight }
        switch matches.count {
        case 0:
            // Not a lost display — a window. A window share's size only
            // coincidentally equals a monitor's, and when it does (a
            // fullscreen window) the rect is the same anyway, so treating that
            // as a display match is harmless rather than wrong.
            return .failure(.notADisplay)
        case 1:
            guard let match = matches.first else { return .failure(.unknownGeometry) }
            return .success(match)
        default:
            return .failure(.ambiguousDisplays(count: matches.count))
        }
    }
}
