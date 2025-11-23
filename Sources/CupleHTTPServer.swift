import Foundation
import TailscaleKit

/// Lightweight HTTP server for serving Cuple metadata over Tailscale
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

    func start(tailscaleHandle: OpaquePointer) async throws {
        guard !isRunning else { return }

        print("🌐 [HTTP] Starting metadata server on Tailscale port \(port)...")

        // Create Tailscale listener (just like the screen share server)
        let listener = try await Listener(
            tailscale: tailscaleHandle,
            proto: .tcp,
            address: ":\(port)",
            logger: SimpleLogger()
        )

        self.listener = listener
        isRunning = true

        print("✅ Metadata server listening on Tailscale port \(port)")

        // Start accepting connections
        Task {
            await acceptConnections()
        }
    }

    private func acceptConnections() async {
        guard let listener = listener else { return }

        while isRunning {
            do {
                let connection = try await listener.accept(timeout: 10.0)
                // Handle connection in background
                Task {
                    await handleConnection(connection)
                }
            } catch {
                // Timeout - continue
                continue
            }
        }
    }

    struct SimpleLogger: LogSink {
        var logFileHandle: Int32? = nil
        func log(_ message: String) {
            print("[HTTP] \(message)")
        }
    }

    private func handleConnection(_ connection: IncomingConnection) async {
        print("🌐 [HTTP] New connection from: \(await connection.remoteAddress ?? "unknown")")

        do {
            // Read HTTP request
            let data = try await connection.receive(maximumLength: 4096, timeout: 5_000)

            guard let request = String(data: data, encoding: .utf8) else {
                print("❌ [HTTP] Failed to parse request")
                await connection.close()
                return
            }

            print("📥 [HTTP] Request: \(request.prefix(100))...")

            // Parse request
            let lines = request.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                await connection.close()
                return
            }

            let parts = requestLine.components(separatedBy: " ")
            guard parts.count >= 2, parts[0] == "GET", parts[1] == "/api/metadata" else {
                await sendResponse(connection, status: 404, body: "Not Found")
                return
            }

            // Get metadata
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
                await sendResponse(connection, status: 500, body: "Failed to get metadata: \(error)")
            }
        } catch {
            print("❌ [HTTP] Error handling connection: \(error)")
        }

        await connection.close()
    }

    private func sendJSON(_ conn: NWConnection, data: Data) async {
        let response =
            "HTTP/1.1 200 OK\r\n" + "Content-Type: application/json\r\n"
            + "Content-Length: \(data.count)\r\n" + "Connection: close\r\n\r\n"

        var fullResponse = Data()
        fullResponse.append(response.data(using: .utf8)!)
        fullResponse.append(data)

        conn.send(
            content: fullResponse,
            completion: .contentProcessed { _ in
                conn.cancel()
            })
    }

    private func sendResponse(_ conn: NWConnection, status: Int, body: String) async {
        let statusText = status == 200 ? "OK" : status == 404 ? "Not Found" : "Error"
        let response =
            "HTTP/1.1 \(status) \(statusText)\r\n" + "Content-Type: text/plain\r\n"
            + "Content-Length: \(body.utf8.count)\r\n" + "Connection: close\r\n\r\n\(body)"

        if let data = response.data(using: .utf8) {
            conn.send(
                content: data,
                completion: .contentProcessed { _ in
                    conn.cancel()
                })
        }
    }

    func stop() async {
        isRunning = false
        listener?.cancel()
        listener = nil
        print("🛑 Metadata server stopped")
    }
}
