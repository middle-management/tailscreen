import Foundation
import TailscaleKit

/// Lightweight HTTP server for serving Cuple metadata over Tailscale.
/// Uses TailscaleKit's Listener + IncomingConnection.send() for bidirectional HTTP.
@available(macOS 10.15, *)
actor CupleHTTPServer {
    private let port: UInt16
    private var listener: Listener?
    private var isRunning = false
    private weak var metadataService: CupleMetadataService?

    init(port: UInt16 = 7448, metadataService: CupleMetadataService) {
        self.port = port
        self.metadataService = metadataService
    }

    func start(node: TailscaleNode) async throws {
        guard !isRunning else { return }

        guard let tailscaleHandle = await node.tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        print("🌐 [HTTP] Starting metadata server on Tailscale port \(port)...")

        let listener = try await Listener(
            tailscale: tailscaleHandle,
            proto: .tcp,
            address: ":\(port)",
            logger: SimpleLogger()
        )

        self.listener = listener
        isRunning = true

        print("✅ Metadata server listening on Tailscale port \(port)")

        Task { [weak self] in
            await self?.acceptConnections()
        }
    }

    private func acceptConnections() async {
        guard let listener = listener else { return }

        while isRunning {
            do {
                let connection = try await listener.accept(timeout: 10.0)
                Task {
                    await handleConnection(connection)
                }
            } catch {
                continue
            }
        }
    }

    private func handleConnection(_ connection: IncomingConnection) async {
        let addr = await connection.remoteAddress ?? "unknown"
        print("🌐 [HTTP] New connection from: \(addr)")

        do {
            let data = try await connection.receive(maximumLength: 4096, timeout: 5_000)

            guard let request = String(data: data, encoding: .utf8) else {
                await connection.close()
                return
            }

            print("📥 [HTTP] Request: \(request.prefix(80))")

            let lines = request.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                await connection.close()
                return
            }

            let parts = requestLine.components(separatedBy: " ")
            guard parts.count >= 2 else {
                await sendResponse(connection, status: 400, body: "Bad Request")
                return
            }

            let method = parts[0]
            let path = parts[1]

            if method == "GET" && path == "/api/metadata" {
                await handleMetadata(connection)
            } else {
                await sendResponse(connection, status: 404, body: "Not Found")
            }
        } catch {
            print("❌ [HTTP] Error handling connection: \(error)")
            await connection.close()
        }
    }

    private func handleMetadata(_ connection: IncomingConnection) async {
        guard let metadataService = metadataService else {
            await sendResponse(connection, status: 500, body: "Service unavailable")
            return
        }

        do {
            let jsonData = try await MainActor.run {
                try metadataService.getMetadataJSON()
            }
            print("✅ [HTTP] Sending metadata: \(jsonData.count) bytes")
            await sendJSON(connection, data: jsonData)
        } catch {
            await sendResponse(connection, status: 500, body: "Failed to get metadata")
        }
    }

    private func sendJSON(_ connection: IncomingConnection, data: Data) async {
        let header =
            "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Connection: close\r\n\r\n"

        var response = Data()
        response.append(header.data(using: .utf8)!)
        response.append(data)

        await sendAndClose(connection, data: response)
    }

    private func sendResponse(_ connection: IncomingConnection, status: Int, body: String) async {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Error"
        }

        let response =
            "HTTP/1.1 \(status) \(statusText)\r\n"
            + "Content-Type: text/plain\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + body

        if let data = response.data(using: .utf8) {
            await sendAndClose(connection, data: data)
        }
    }

    private func sendAndClose(_ connection: IncomingConnection, data: Data) async {
        do {
            try await connection.send(data)
        } catch {
            print("❌ [HTTP] Send failed: \(error)")
        }
        await connection.close()
    }

    func stop() async {
        isRunning = false
        await listener?.close()
        listener = nil
        print("🛑 Metadata server stopped")
    }
}

private struct SimpleLogger: LogSink {
    var logFileHandle: Int32? = nil
    func log(_ message: String) {
        print("[HTTP] \(message)")
    }
}
