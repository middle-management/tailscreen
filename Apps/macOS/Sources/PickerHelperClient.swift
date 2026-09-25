import Foundation
import os

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

/// Wrapper around the `Tailscreen --picker-helper` child. Transactional, not
/// long-lived: each call spawns a fresh helper, gets one selection, and the
/// helper exits — no XPC state from the picker UI session lives in the same
/// PID as the SCStream-driving capture helper.
enum PickerHelperClient {
    /// Returns JSON-encoded `PickerSelection` bytes, or `nil` if cancelled.
    static func run(timeoutSeconds: TimeInterval = 120) async throws -> Data? {
        guard let exe = resolveHelperExecutable() else {
            throw PickerHelperClientError.executableNotFound
        }
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["--picker-helper"]

        let stdoutPipe = Pipe()
        proc.standardOutput = stdoutPipe
        // Inherit stderr so picker-helper warnings land in the merged log.

        try proc.run()

        let handle = stdoutPipe.fileHandleForReading

        // Off the main actor: the read happens after the picker UI
        // interacted with the user, so it can take arbitrarily long.
        let readTask = Task<Data?, Never> {
            await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: readFramed(handle))
                }
            }
        }

        // SCContentSharingPicker has been observed to never fire its selection
        // callback on some macOS builds, with no internal timeout — without
        // this, `readFramed` blocks forever. SIGTERM on deadline; closing
        // stdout unblocks the read (-> nil). Captures the pid, not the
        // non-Sendable `Process`, to keep the Task closure Sendable.
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let pid = proc.processIdentifier
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            if Task.isCancelled { return }
            timedOut.withLock { $0 = true }
            kill(pid, SIGTERM)
        }

        let payload = await readTask.value
        watchdog.cancel()

        // A real selection wins even if the watchdog fired at the same instant.
        if payload == nil, timedOut.withLock({ $0 }) {
            proc.waitUntilExit()
            throw PickerHelperClientError.timedOut
        }

        // SCContentSharingPicker is a process-wide singleton; wait for full
        // exit so the next spawn doesn't race this one's teardown.
        proc.waitUntilExit()

        if proc.terminationStatus >= 2 {
            throw PickerHelperClientError.helperFailed(
                exitCode: Int(proc.terminationStatus))
        }

        return payload
    }

    /// `[len:4 BE][bytes:len]`, matching `PickerHelperFraming` exactly.
    /// `nil` for `len == 0` (cancelled) or any read error/EOF. Internal so
    /// `WireByteRegistryTests` can round-trip writer -> reader.
    static func readFramed(_ handle: FileHandle) -> Data? {
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
    case timedOut
}
