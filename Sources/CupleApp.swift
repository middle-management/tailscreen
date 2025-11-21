import SwiftUI

@main
struct CupleApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Cuple", systemImage: "tv") {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
