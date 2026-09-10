import SwiftCrossUI
import TailscreenL10n

/// What the hub shows while a peer list is being built: "Looking for
/// screens…" over placeholder rows.
///
/// The macOS hub has had a skeleton since it grew a peer list; both
/// swift-cross-ui hubs showed only a centered status line in the middle of an
/// otherwise empty window, which reads as *nothing is here* rather than *this
/// is where the screens will be*. Shape is what carries that difference: rows
/// in the place rows will occupy say the list is coming, without claiming a
/// count.
///
/// Three deliberate differences from `PeerRowSkeleton` on macOS.
///
/// The status line stays, as visible text above the rows. macOS hides the
/// equivalent in an `accessibilityLabel` on a purely decorative block, and
/// swift-cross-ui surfaces no accessibility modifiers at all — so the choice
/// here is between saying it on screen and not saying it anywhere. On screen
/// is also just clearer.
///
/// The rows do not pulse. That skeleton animates `repeatForever` and gates it
/// on `accessibilityReduceMotion`; with no such environment value here, an
/// animation could not be turned off by somebody who needs it off. A static
/// placeholder is the honest version of the idea rather than a worse-behaved
/// copy of it.
///
/// And the row count is fixed rather than remembered from the last settled
/// list. macOS persists that count so the list does not resize as it lands;
/// doing the same means another stored value per host for a cosmetic gain,
/// which is not worth it before either app has one.
public struct HubScreenSkeleton: View {
    /// Enough rows to read as a list, few enough not to promise a tailnet
    /// bigger than the person has.
    private static let rowCount = 3

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Said here rather than taken from the host's status line: this
            // block renders exactly one state, and the two hosts' status
            // strings do not both name it — the WinUI hub leaves its own on
            // "Signed in as …" through a sweep, which over placeholder rows
            // would head the list with an account name.
            Text(L("Looking for screens…"))
                .font(.callout)
                .foregroundColor(HubStyle.secondaryText)
            VStack(spacing: 6) {
                ForEach(Array(0..<Self.rowCount), id: \.self) { index in
                    row(index: index)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One placeholder, laid out like `SharerRow` so the real rows land in
    /// the same places rather than shifting everything when they arrive.
    private func row(index: Int) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(HubStyle.offline)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 4) {
                // Varied widths so the block reads as a list of different
                // machines rather than a striped rectangle.
                bar(width: index == 1 ? 120 : 150)
                bar(width: index == 2 ? 84 : 100, faint: true)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: HubStyle.rowRadius).fill(HubStyle.rowFill))
    }

    private func bar(width: Double, faint: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(faint ? HubStyle.tertiaryText : HubStyle.secondaryText)
            .frame(width: width, height: faint ? 8 : 10)
    }
}
