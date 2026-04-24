import Darwin
import Foundation
import TailscaleKit

extension IncomingConnection {
    /// Write data to the connection using POSIX write()
    /// Accesses the underlying file descriptor via reflection
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

extension OutgoingConnection {
    /// Write data to the connection using POSIX write() via the underlying fd.
    /// TailscaleKit doesn't expose a public write API on `OutgoingConnection`,
    /// so we mirror the approach used for ``IncomingConnection`` above: reach
    /// the private `conn` property via reflection and call `Darwin.write`.
    func write(_ data: Data) async throws -> Int {
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

    /// Send complete data (loops until every byte is written).
    func send(_ data: Data) async throws {
        var remaining = data
        while !remaining.isEmpty {
            let written = try await write(remaining)
            remaining.removeFirst(written)
        }
    }
}
