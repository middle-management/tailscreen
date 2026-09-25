import SwiftCrossUI
import TailscreenL10n

/// What the hub shows while a peer list is being built: "Looking for
/// screens…" over placeholder rows, instead of a bare centered status line
/// that reads as *nothing is here*.
///
/// Differences from macOS's `PeerRowSkeleton`: the status line stays visible
/// (swift-cross-ui has no accessibility modifiers to hide it in); rows don't
/// pulse (no `accessibilityReduceMotion` here to gate the animation on); and
/// the row count is fixed rather than remembered from the last settled list.
public struct HubScreenSkeleton: View {
    /// Enough rows to read as a list, few enough not to promise a tailnet
    /// bigger than the person has.
    private static let rowCount = 3

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Said here, not taken from the host's status line — WinUI's stays
            // on "Signed in as …" through a sweep, wrong over placeholder rows.
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

    /// One placeholder, laid out like `SharerRow` so real rows land in the
    /// same places when they arrive.
    private func row(index: Int) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(HubStyle.offline)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 4) {
                // Varied widths so this reads as machines, not a striped rectangle.
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
