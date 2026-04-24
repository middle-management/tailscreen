import Darwin
import Foundation
import TailscaleKit

extension IncomingConnection {
    /// Write data to the connection using POSIX write(), accessed via
    /// reflection on the underlying file descriptor.
    ///
    /// Works for TCP (stream socket) unconditionally. For UDP it works
    /// **iff** TailscaleKit hands us an FD that has already been
    /// `connect()`-ed to the peer (connected UDP socket), which is the
    /// normal shape when `Listener(proto: .udp)` per-peer demuxes via
    /// `accept()`. If instead the FD is an unconnected UDP socket, this
    /// call will fail with `ENOTCONN` and the fix is to replace the
    /// `Darwin.write` below with `Darwin.sendto` + a peer address.
    func write(_ data: Data) async throws -> Int {
        // Use Mirror to access the private conn field
        let mirror = Mirror(reflecting: self)
        var connValue: TailscaleConnection = 0

        for child in mirror.children {
            if child.label == "conn" {
                if let conn = child.value as? TailscaleConnection {
                    connValue = conn
                    break
                }
            }
        }

        guard connValue != 0 else {
            throw NSError(
                domain: "TailscaleConnection",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Connection not available"]
            )
        }

        var bytesWritten = 0
        try data.withUnsafeBytes { buffer in
            let result = Darwin.write(connValue, buffer.baseAddress!, data.count)
            if result < 0 {
                throw NSError(
                    domain: "TailscaleConnection",
                    code: Int(errno),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Failed to write to connection: \(String(cString: strerror(errno)))"
                    ]
                )
            }
            bytesWritten = Int(result)
        }
        return bytesWritten
    }

    /// Send complete data to the connection
    func send(_ data: Data) async throws {
        var remaining = data
        while !remaining.isEmpty {
            let written = try await write(remaining)
            remaining.removeFirst(written)
        }
    }
}
