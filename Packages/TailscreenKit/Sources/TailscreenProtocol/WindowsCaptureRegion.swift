import Foundation

/// Works out WHERE a Windows capture target is on screen, when the platform
/// won't say.
///
/// A WGC `GraphicsCaptureItem` is opaque: it has a size and a display name
/// but no HMONITOR or HWND — fine for capturing, fatal for remote control,
/// which needs to turn a normalized `[0, 1]` coordinate into a screen pixel.
///
/// The only signal is the item's size, matched against enumerated monitors.
/// **Two monitors of the same resolution are indistinguishable this way** —
/// a dual 1920×1080 desk is common, not exotic — so the rule is *unique
/// match or nothing*: an ambiguous answer declines remote control rather
/// than risk a click landing on the wrong monitor.
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
            // Not a lost display — a window. A fullscreen window's size
            // coincidentally matching a monitor's is harmless, not wrong.
            return .failure(.notADisplay)
        case 1:
            guard let match = matches.first else { return .failure(.unknownGeometry) }
            return .success(match)
        default:
            return .failure(.ambiguousDisplays(count: matches.count))
        }
    }
}
