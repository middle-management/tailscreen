import Foundation
import Network

/// Lightweight HTTP server for serving Cuple metadata
/// Listens on Tailscale interface by binding to Tailscale IP
@available(macOS 10.15, *)
actor CupleHTTPServer {
    private let port: UInt16
    private var listener: NWListener?
    private var isRunning = false
    private weak var metadataService: CupleMetadataService?
    private var tailscaleIP: String?

    init(port: UInt16 = 7448, metadataService: CupleMetadataService) {
        self.port = port
        self.metadataService = metadataService
    }

    func start(tailscaleIP: String? = nil) async throws {
        guard !isRunning else { return }

        self.tailscaleIP = tailscaleIP

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = false  // Accept connections from all interfaces

        // Don't restrict interface type - let it bind to all including Tailscale
        // params.requiredInterfaceType = .other

        if let ip = tailscaleIP {
            print("🌐 [HTTP] Starting server for Tailscale IP: \(ip):\(port)")
        }

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port)) else {
            throw NSError(
                domain: "CupleHTTPServer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create listener"])
        }

        self.listener = listener
        isRunning = true

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleConnection(connection) }
        }

        listener.start(queue: .global(qos: .userInitiated))
        print("✅ Metadata server listening on 0.0.0.0:\(port) (all interfaces)")
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        print("🌐 [HTTP] New connection received")

        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, _, error in

            if let error = error {
                print("❌ [HTTP] Connection error: \(error)")
                conn.cancel()
                return
            }

            guard let self = self, let data = data,
                let request = String(data: data, encoding: .utf8)
            else {
                print("❌ [HTTP] Failed to parse request")
                conn.cancel()
                return
            }

            print("📥 [HTTP] Request: \(request.prefix(100))...")

            Task {
                // Parse request line (e.g., "GET /api/metadata HTTP/1.1")
                let lines = request.components(separatedBy: "\r\n")
                guard let requestLine = lines.first else {
                    conn.cancel()
                    return
                }

                let parts = requestLine.components(separatedBy: " ")
                guard parts.count >= 2, parts[0] == "GET", parts[1] == "/api/metadata" else {
                    await self.sendResponse(conn, status: 404, body: "Not Found")
                    return
                }

                // Get metadata
                guard let metadataService = await self.metadataService else {
                    await self.sendResponse(conn, status: 500, body: "Service unavailable")
                    return
                }

                do {
                    let jsonData = try await MainActor.run {
                        try metadataService.getMetadataJSON()
                    }
                    print("✅ [HTTP] Sending metadata: \(jsonData.count) bytes")
                    await self.sendJSON(conn, data: jsonData)
                } catch {
                    await self.sendResponse(conn, status: 500, body: "Failed to get metadata")
                }
            }
        }
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
