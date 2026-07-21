import DefaultBackend
import Foundation
import SwiftCrossUI
import TailscreenViewer
import TailscreenViewerGtk

// tailscreen-viewer-gtk — native GTK desktop viewer (L0a skeleton).
//
//   tailscreen-viewer-gtk [--render-self-test]
//
// L0a shows a placeholder colour-bars frame in a native GTK window via the
// downstream GtkVideoView. `--render-self-test` renders the bars, reads the
// pixels back, and exits 0 on correct BT.709 output / non-zero otherwise — the
// headless CI render gate (run under xvfb-run). The live tsnet transport lands
// in L0b.

// swift-cross-ui's `App.main()` default-constructs the app, so shared state
// lives at module scope.
let gStore = FrameStore()
let gSelfTest = CommandLine.arguments.contains("--render-self-test")
gStore.set(makeColorBarsFrame())

struct ViewerApp: App {
    var body: some Scene {
        WindowGroup("Tailscreen viewer") {
            GtkVideoView(store: gStore, selfTest: gSelfTest)
        }
        .defaultSize(width: 512, height: 288)
    }
}

ViewerApp.main()
