import Foundation

/// Resolve the Tailscreen executable that should be spawned as a helper
/// (`--capture-helper` / `--picker-helper`). Honours `TAILSCREEN_HELPER_EXE`
/// — set by XCTest, where `Bundle.main` points at the xctest harness, not
/// Tailscreen. Production launches fall through to `Bundle.main.executableURL`.
func resolveHelperExecutable() -> URL? {
    let override = ProcessInfo.processInfo.environment["TAILSCREEN_HELPER_EXE"]
    if let override, !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    return Bundle.main.executableURL
}

/// Main-process wrapper around the `Tailscreen --picker-helper` child.
/// Spawns it, reads exactly one framed payload (`[len:4 BE][bytes]`)
/// off stdout, returns the archived `SCContentFilter` bytes (or `nil`
/// if the user cancelled), then waits for the helper to exit.
///
/// We keep this transactional rather than long-lived: each call
/// spawns a fresh helper, gets one selection, and the helper exits.
/// That's the architectural payoff for keeping the picker out of the
/// long-running main process — no XPC state from the picker UI
/// session ever lives in the same PID as the SCStream-driving capture
/// helper.
enum PickerHelperClient {
    /// Spawn the picker helper and await the user's selection.
    /// Returns the JSON-encoded `PickerSelection` bytes for the
    /// chosen content, or `nil` if the user cancelled.
    static func run() async throws -> Data? {
        guard let exe = resolveHelperExecutable() else {
            throw PickerHelperClientError.executableNotFound
        }
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["--picker-helper"]

        let stdoutPipe = Pipe()
        proc.standardOutput = stdoutPipe
        // Inherit stderr so any picker-helper warnings / errors land in
        // the merged log alongside the parent's logs.

        try proc.run()

        let handle = stdoutPipe.fileHandleForReading

        // Hop the blocking pipe reads off the main actor. The helper
        // only writes one frame, but the read happens after macOS's
        // picker UI has interacted with the user, so this can take
        // arbitrarily long.
        let payload: Data? = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = readFramed(handle)
                cont.resume(returning: result)
            }
        }

        // Ensure the helper has fully exited before we return so the
        // parent's next picker spawn doesn't race against teardown of
        // the previous one. macOS keeps the SCContentSharingPicker
        // singleton process-wide; serializing across separate child
        // PIDs avoids any cross-talk between sessions.
        proc.waitUntilExit()

        if proc.terminationStatus >= 2 {
            throw PickerHelperClientError.helperFailed(
                exitCode: Int(proc.terminationStatus))
        }

        return payload
    }

    /// Read one framed payload (`[len:4 BE][bytes:len]`) off the pipe.
    /// Returns `nil` for `len == 0` (user cancelled) and for any read
    /// error / EOF — the caller treats both as "no selection". Matches
    /// the picker helper's wire format exactly; if you change one
    /// side, change the other.
    private static func readFramed(_ handle: FileHandle) -> Data? {
        guard let header = readExactly(handle, count: 4), header.count == 4 else {
            return nil
        }
        let len =
            (UInt32(header[0]) << 24) | (UInt32(header[1]) << 16) | (UInt32(header[2]) << 8) | UInt32(header[3])
        if len == 0 {
            return nil
        }
        return readExactly(handle, count: Int(len))
    }

    private static func readExactly(_ handle: FileHandle, count: Int) -> Data? {
        var collected = Data()
        collected.reserveCapacity(count)
        while collected.count < count {
            let need = count - collected.count
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: need) else { return nil }
                chunk = read
            } catch {
                return nil
            }
            if chunk.isEmpty { return nil }
            collected.append(chunk)
        }
        return collected
    }
}

enum PickerHelperClientError: Error {
    case executableNotFound
    case helperFailed(exitCode: Int)
}
