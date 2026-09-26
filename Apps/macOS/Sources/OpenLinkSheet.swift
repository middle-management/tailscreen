import SwiftUI

/// Viewer-side "Open a Link on the Sharer" sheet, presented on the viewer
/// window by `AppState.presentOpenLinkSheet`. A rejected link keeps the
/// sheet open with the reason inline, so the user can fix it in place.
struct OpenLinkSheet: View {
    let onSend: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void

    @State private var text = ""
    @State private var rejected = false
    @FocusState private var fieldFocused: Bool

    init(onSend: @escaping @MainActor (String) -> Void, onCancel: @escaping @MainActor () -> Void) {
        self.onSend = onSend
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Open a Link on the Sharer"))
                .font(.headline)
            Text(L("The sharer sees the whole link and chooses whether to open it."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(text: $text, prompt: Text(verbatim: "https://")) {
                Text(L("Open a Link on the Sharer"))
            }
            .textFieldStyle(.roundedBorder)
            .font(.body.monospaced())
            .focused($fieldFocused)
            .onSubmit { send() }
            .onChange(of: text) { rejected = false }
            if rejected {
                Text(
                    L(
                        "That isn't a link the sharer can open. Use a full http:// or https:// address with no spaces."
                    )
                )
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(L("Send")) {
                    send()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { fieldFocused = true }
    }

    private func send() {
        guard let url = OpenLinkEntry.sendable(text) else {
            rejected = true
            return
        }
        onSend(url)
    }
}
