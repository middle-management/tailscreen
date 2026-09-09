#!/usr/bin/env python3
"""Fixtures for check-callback-isolation.py.

A checker that fails open is worse than no checker: it converts "nobody looked"
into "CI says it is fine". This one failed open twice while it was being
written — once because the enclosing type was found by walking back to the
nearest declaration of any indentation (a closed nested type answered for the
class that really enclosed the call), and once because a wrapped signature's
`    ) {` closer sits at the declaration's own indentation and hid the
`nonisolated` that made the call safe. Both are fixtures here.
"""

import subprocess
import sys
from pathlib import Path

CHECKER = Path(__file__).resolve().parent / "check-callback-isolation.py"

# (name, expected-finding-count, source)
CASES = [
    ("trailing closure in a @MainActor type", 1, """
@MainActor
final class MicCapture {
    private func scheduleSamples(_ samples: [Float]) {
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in self?.pendingBuffers -= 1 }
        }
    }
}
"""),
    ("a closed nested type between the call and its class", 1, """
@MainActor
final class MicCapture {
    private final class TestToneState: @unchecked Sendable {
        var phase: Double = 0
    }

    private func scheduleSamples(_ samples: [Float]) {
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in self?.pendingBuffers -= 1 }
        }
    }
}
"""),
    ("wrapped argument list, then a trailing closure", 1, """
@MainActor
final class MicCapture {
    func start() {
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nil
        ) { avBuffer, _ in
            buffer.process(avBuffer)
        }
    }
}
"""),
    ("trailing closure with no argument list", 1, """
@MainActor
final class SharerNoticeCenter {
    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in self.apply(settings) }
        }
    }
}
"""),
    ("inline closure argument", 1, """
@MainActor
final class SharerNoticeCenter {
    func ensureAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert], completionHandler: { granted, _ in
                Task { @MainActor in self.record(granted) }
            })
    }
}
"""),
    ("closure literal inside an actor", 1, """
actor LinkSession {
    func start() {
        stream.startCapture { error in
            print(error as Any)
        }
    }
}
"""),
    ("handler bound to an explicitly @Sendable local", 0, """
@MainActor
final class MicCapture {
    private func scheduleSamples(_ samples: [Float]) {
        let onConsumed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.pendingBuffers -= 1 }
        }
        player.scheduleBuffer(buffer, completionHandler: onConsumed)
    }
}
"""),
    ("nonisolated function with a wrapped signature", 0, """
@MainActor
final class MicCapture {
    nonisolated private static func installTap(
        on inputNode: AVAudioInputNode,
        buffer: TapBuffer
    ) {
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nil
        ) { avBuffer, _ in
            buffer.process(avBuffer)
        }
    }
}
"""),
    ("a type that is not actor-isolated", 0, """
class ScreenCapture: NSObject, @unchecked Sendable {
    private static func stopCaptureWatchdogged(stream: SCStream) async {
        stream.stopCapture { err in
            print(err as Any)
        }
    }
}
"""),
    ("an API named only in a comment", 0, """
@MainActor
final class MicCapture {
    // AVAudioPlayerNode.scheduleBuffer { … } inherits isolation — see the
    // installTap { … } seam below for the dodge.
    func noop() {}
}
"""),
]


def main():
    failures = 0
    for name, expected, source in CASES:
        proc = subprocess.run(
            [sys.executable, str(CHECKER), "-"],
            input=source, capture_output=True, text=True,
        )
        found = proc.stdout.count("error:")
        status = "ok" if found == expected else "FAIL"
        if found != expected:
            failures += 1
            print("%-4s %s: expected %d finding(s), got %d\n%s"
                  % (status, name, expected, found, proc.stdout))
        else:
            print("%-4s %s" % (status, name))
    if failures:
        print("\n%d fixture(s) failed — the checker does not do what it claims."
              % failures)
        return 1
    print("\n%d fixtures pass." % len(CASES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
