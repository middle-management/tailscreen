import AppKit
import Combine
import SwiftUI

// MARK: - Session-ended overlay

/// State + wiring for the "session ended" pane drawn over the viewer
/// window's last frame when the session ends without the user asking —
/// sharer stop, idle timeout, connection loss, or a deny/kick. Replaces
/// the old behaviour of the window silently vanishing.
@MainActor
final class ViewerSessionEndedModel: ObservableObject {
    struct EndedState: Equatable {
        let title: String
        let message: String
    }

    @Published var state: EndedState?
    /// Redials the peer of the session that just ended
    /// (`AppState.reconnectViewerSession`).
    var onReconnect: (@MainActor () -> Void)?
    /// Orders the viewer window out (`AppState.dismissViewerWindow`).
    var onClose: (@MainActor () -> Void)?
}

/// Centered card over a dimmed copy of the last frame: why the session
/// ended, a prominent Reconnect, and a Close. Modelled on
/// ``ViewerShortcutsOverlay``'s card styling so the viewer's overlays read
/// as one family.
struct ViewerSessionEndedOverlay: View {
    @ObservedObject var model: ViewerSessionEndedModel

    var body: some View {
        ZStack {
            // Dim the frozen last frame beneath. Deliberately NOT
            // tap-to-dismiss — leaving is a decision the two buttons carry;
            // the backdrop only swallows clicks so the annotation canvas
            // underneath doesn't receive them.
            Color.black.opacity(0.55)
                .contentShape(Rectangle())

            if let state = model.state {
                card(state)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.state?.title ?? L("Session Ended"))
    }

    private func card(_ state: ViewerSessionEndedModel.EndedState) -> some View {
        VStack(spacing: 12) {
            Text(state.title)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(state.message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(L("Reconnect")) {
                    model.onReconnect?()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Button(L("Close")) {
                    model.onClose?()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 28)
        .frame(maxWidth: 420)
        .background(
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 14, x: 0, y: 4)
        .padding(40)
    }
}

/// Wraps `ViewerSessionEndedOverlay` in an `NSHostingView` pinned to the
/// viewer's full content view; hidden whenever `model.state` is nil. Same
/// pattern as `ViewerShortcutsOverlayHost`.
@MainActor
final class ViewerSessionEndedOverlayHost {
    let view: NSHostingView<ViewerSessionEndedOverlay>
    let model: ViewerSessionEndedModel
    private var visibilityCancellable: AnyCancellable?

    init(model: ViewerSessionEndedModel = ViewerSessionEndedModel()) {
        self.model = model
        let host = NSHostingView(rootView: ViewerSessionEndedOverlay(model: model))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.isHidden = model.state == nil
        self.view = host
        self.visibilityCancellable = model.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak host] state in
                host?.isHidden = state == nil
            }
    }

    /// Pin the overlay to fill `parent`. Caller adds `view` as a subview
    /// before calling.
    func layout(in parent: NSView) {
        view.frame = parent.bounds
        view.autoresizingMask = [.width, .height]
    }
}

// MARK: - Non-modal notice banner

/// One in-window notice. Transient notices (decode fallback in progress)
/// are auto-dismissed by AppState after a few seconds; persistent ones
/// (the stall ladder's last rung) stay until dismissed or acted on.
struct ViewerNotice {
    let id = UUID()
    let message: String
    let isPersistent: Bool
    let actionTitle: String?
    let action: (@MainActor () -> Void)?

    init(
        message: String,
        isPersistent: Bool,
        actionTitle: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        self.message = message
        self.isPersistent = isPersistent
        self.actionTitle = actionTitle
        self.action = action
    }
}

@MainActor
final class ViewerNoticeBannerModel: ObservableObject {
    @Published var notice: ViewerNotice?
}

/// Top-center banner replacing the mid-session NSAlerts, which parked a
/// modal panel over a live stream. Non-modal: the video keeps playing and
/// the user keeps working underneath it.
struct ViewerNoticeBanner: View {
    @ObservedObject var model: ViewerNoticeBannerModel

    var body: some View {
        if let notice = model.notice {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                Text(notice.message)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if let title = notice.actionTitle {
                    Button(title) {
                        notice.action?()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Button {
                    model.notice = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Dismiss notice"))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                VisualEffectBackground()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
        }
    }
}

/// Pins `ViewerNoticeBanner` top-center in the viewer's content view,
/// below the unified toolbar (same `contentLayoutRect` reasoning as
/// `ViewerStatsOverlayHost`); re-measures whenever the notice changes.
@MainActor
final class ViewerNoticeBannerHost {
    let view: NSHostingView<ViewerNoticeBanner>
    let model: ViewerNoticeBannerModel
    private var noticeCancellable: AnyCancellable?
    private weak var parent: NSView?
    private var inset: CGFloat = 12

    init(model: ViewerNoticeBannerModel = ViewerNoticeBannerModel()) {
        self.model = model
        let host = NSHostingView(rootView: ViewerNoticeBanner(model: model))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = []
        host.isHidden = model.notice == nil
        self.view = host
        self.noticeCancellable = model.$notice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notice in
                self?.view.isHidden = notice == nil
                self?.applyLayout()
            }
    }

    /// Pin the banner into `parent`. Caller adds `view` as a subview
    /// before calling.
    func layout(in parent: NSView, inset: CGFloat = 12) {
        self.parent = parent
        self.inset = inset
        applyLayout()
    }

    private func applyLayout() {
        guard let parent else { return }
        let size = view.fittingSize
        var top = parent.bounds.maxY
        if let window = parent.window {
            let usable = window.contentLayoutRect
            if !usable.isEmpty { top = min(top, usable.maxY) }
        }
        let width = min(size.width, parent.bounds.width - inset * 2)
        let frame = NSRect(
            x: (parent.bounds.width - width) / 2,
            y: top - size.height - inset,
            width: width,
            height: size.height
        )
        if frame != view.frame { view.frame = frame }
        view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
    }
}
