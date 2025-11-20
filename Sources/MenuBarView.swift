import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sharing section
            Group {
                if appState.isSharing {
                    MenuButton("Stop Sharing", systemImage: "stop.circle") {
                        appState.stopSharing()
                    }
                } else {
                    MenuButton("Start Sharing", systemImage: "play.circle") {
                        Task {
                            await appState.startSharing()
                        }
                    }
                }
            }

            Divider()

            // Connection section
            Group {
                if appState.isConnected {
                    MenuButton("Disconnect", systemImage: "xmark.circle") {
                        appState.disconnect()
                    }
                } else {
                    MenuButton("Connect to...", systemImage: "link") {
                        appState.showConnectSheet = true
                    }
                }
            }

            Divider()

            // Info section
            MenuButton("Show IP Address", systemImage: "info.circle") {
                appState.showIPSheet = true
            }

            Divider()

            // Status
            if appState.isSharing {
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.small)
                    Text("Sharing")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            if appState.isConnected {
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundColor(.blue)
                        .imageScale(.small)
                    Text("Connected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Divider()

            // Quit
            Button("Quit") {
                if appState.isSharing {
                    appState.stopSharing()
                }
                if appState.isConnected {
                    appState.disconnect()
                }
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .frame(width: 200)
        .sheet(isPresented: $appState.showConnectSheet) {
            ConnectSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showIPSheet) {
            IPAddressSheet()
                .environmentObject(appState)
        }
        .alert(appState.alertTitle, isPresented: $appState.showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(appState.alertMessage)
        }
    }
}

struct MenuButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

struct ConnectSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var ipAddress = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Connect to Screen Share")
                .font(.headline)

            Text("Enter the IP address of the computer you want to view:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            TextField("192.168.1.100", text: $ipAddress)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Button("Connect") {
                    Task {
                        await appState.connect(to: ipAddress.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
                .keyboardShortcut(.return)
                .disabled(ipAddress.isEmpty)
            }
        }
        .padding()
        .frame(width: 350)
    }
}

struct IPAddressSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Your IP Addresses")
                .font(.headline)

            if appState.localIPAddresses.isEmpty {
                Text("No network interfaces found")
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(appState.localIPAddresses, id: \.self) { address in
                        HStack {
                            Text(address)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(address.components(separatedBy: ": ").last ?? address, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .help("Copy to clipboard")
                        }
                    }
                }
            }

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.return)
        }
        .padding()
        .frame(width: 400)
    }
}
