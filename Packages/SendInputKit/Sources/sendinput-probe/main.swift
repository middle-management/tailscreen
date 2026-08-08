import Foundation
import SendInputKit
import TailscreenProtocol

// Reports what the injector would do, and — only if asked — actually does it.
//
// Two jobs, like every other probe here. The first is to make the LINKER run
// over the shim: a SwiftPM library target is compiled but never linked, which
// is how WASAPIKit's four missing GUID symbols passed their own build step and
// surfaced eleven minutes later in the app.
//
// The second is to answer "is remote control wired up correctly" without
// standing up a share and a viewer. It prints the virtual desktop the mapping
// is anchored to — which is where a multi-monitor setup goes wrong — and the
// exact absolute coordinates a corner click would produce.
//
// It does NOT inject by default, and is not run in CI. Unlike wasapi-probe,
// whose failure mode is silence, this one moves a real cursor: pass `--inject`
// to let it, and expect the pointer to jump to the middle of the desktop.

let desktop = SendInputInjector.virtualDesktop()
print("sendinput-probe: virtual desktop \(desktop)")
if desktop.width <= 1 || desktop.height <= 1 {
    print("sendinput-probe: no usable desktop — this is expected off Windows")
}

let injector = SendInputInjector()
print("sendinput-probe: isTrusted = \(injector.isTrusted())")
print(
    "sendinput-probe: canDriveElevatedWindows = \(injector.canDriveElevatedWindows) "
        + "(false means UIPI will silently discard input aimed at elevated windows)")

// Map the whole desktop as the shared region, so the printed coordinates are
// directly comparable with the 0…65535 range SendInput expects.
let region = desktop

for (label, nx, ny) in [
    ("top-left", 0.0, 0.0), ("centre", 0.5, 0.5), ("bottom-right", 1.0, 1.0)
] {
    let point = WindowsPointerMapping.absolutePoint(
        normalizedX: nx, normalizedY: ny, in: region, virtualDesktop: desktop)
    print("sendinput-probe: \(label) (\(nx), \(ny)) → absolute \(point.x), \(point.y)")
}

guard CommandLine.arguments.contains("--inject") else {
    print("sendinput-probe: pass --inject to actually move the pointer")
    exit(0)
}

injector.activate(region: region)
injector.apply(.mouseMove(x: 0.5, y: 0.5))
print("sendinput-probe: moved the pointer to the centre of the desktop")
// Give the serial queue a moment; this program's whole life is shorter than
// the async hop otherwise.
Thread.sleep(forTimeInterval: 0.2)
injector.deactivate()
