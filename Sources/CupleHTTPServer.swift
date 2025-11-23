import Foundation
import Network

/// Simple HTTP server for serving Cuple metadata
@available(macOS 10.15, *)
actor CupleHTTPServer {
    private let port: UInt16
    private var listener: NWListener?
    private var isRunning = false
    private weak var metadataService: CupleMetadataService?
    private var connectionTasks: [Task<Void, Never>] = []

    init(port: UInt16 = 7448, metadataService: CupleMetadataService) {
        self.port = port
        self.metadataService = metadataService
    }

    /// Start the HTTP server on all interfaces (including Tailscale)
    func start() async throws {
        guard !isRunning else { return }

        print("🌐 Starting HTTP server on port \(port)...")

        // Create TCP listener
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port)) else {
            throw NSError(domain: "CupleHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create listener"])
        }

        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleStateUpdate(state) }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleNewConnection(connection) }
        }

        listener.start(queue: .global(qos: .userInitiated))
        isRunning = true

        print("✅ HTTP server listening on port \(port)")
    }

    private func handleStateUpdate(_ state: NWListener.State) {
        switch state {
        case .ready:
            print("🌐 HTTP server is ready")
        case .failed(let error):
            print("❌ HTTP server failed: \(error)")
        case .cancelled:
            print("🛑 HTTP server cancelled")
        default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        let handleTask = Task {
            await handleConnection(connection)
        }
        connectionTasks.append(handleTask)
    }

    private func handleConnection(_ connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Receive HTTP request
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
                Task {
                    guard let self = self else { return }

                    if let error = error {
                        print("❌ HTTP receive error: \(error)")
                        connection.cancel()
                        continuation.resume()
                        return
                    }

                    guard let data = data, let requestString = String(data: data, encoding: .utf8) else {
                        await self.sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
                        connection.cancel()
                        continuation.resume()
                        return
                    }

                    // Parse request line
                    let lines = requestString.components(separatedBy: "\r\n")
                    guard let requestLine = lines.first else {
                        await self.sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
                        connection.cancel()
                        continuation.resume()
                        return
                    }

                    let parts = requestLine.components(separatedBy: " ")
                    guard parts.count >= 2 else {
                        await self.sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
                        connection.cancel()
                        continuation.resume()
                        return
                    }

                    let method = parts[0]
                    let path = parts[1]

                    // Route the request
                    if path == "/api/metadata" && method == "GET" {
                        await self.handleMetadataRequest(connection: connection)
                    } else if path == "/api/request" && method == "POST" {
                        // Extract body from request
                        if let bodyStart = requestString.range(of: "\r\n\r\n") {
                            let body = String(requestString[bodyStart.upperBound...])
                            await self.handleRequestEndpoint(connection: connection, body: body)
                        } else {
                            await self.sendResponse(connection: connection, statusCode: 400, body: "Missing body")
                        }
                    } else {
                        await self.sendResponse(connection: connection, statusCode: 404, body: "Not Found")
                    }

                    connection.cancel()
                    continuation.resume()
                }
            }
        }
    }

    private func handleMetadataRequest(connection: NWConnection) async {
        guard let metadataService = metadataService else {
            await sendResponse(connection: connection, statusCode: 500, body: "Service unavailable")
            return
        }

        do {
            let jsonData = try await MainActor.run {
                try metadataService.getMetadataJSON()
            }

            await sendJSONResponse(connection: connection, data: jsonData)
        } catch {
            await sendResponse(connection: connection, statusCode: 500, body: "Failed to get metadata: \(error)")
        }
    }

    private func handleRequestEndpoint(connection: NWConnection, body: String) async {
        guard let metadataService = metadataService,
              let bodyData = body.data(using: .utf8) else {
            await sendResponse(connection: connection, statusCode: 400, body: "Invalid request")
            return
        }

        do {
            let request = try JSONDecoder().decode(CupleRequest.self, from: bodyData)

            switch request {
            case .requestToShare(let from):
                await MainActor.run {
                    metadataService.handleRequestToShare(from: from)
                }
                await sendResponse(connection: connection, statusCode: 200, body: "OK")
            default:
                await sendResponse(connection: connection, statusCode: 400, body: "Invalid request type")
            }
        } catch {
            await sendResponse(connection: connection, statusCode: 400, body: "Failed to parse request: \(error)")
        }
    }

    private func sendJSONResponse(connection: NWConnection, data: Data) async {
        let statusLine = "HTTP/1.1 200 OK\r\n"
        let headers = "Content-Type: application/json\r\n" +
                     "Content-Length: \(data.count)\r\n" +
                     "Connection: close\r\n" +
                     "\r\n"

        var responseData = Data()
        responseData.append(statusLine.data(using: .utf8)!)
        responseData.append(headers.data(using: .utf8)!)
        responseData.append(data)

        await sendData(connection: connection, data: responseData)
    }

    private func sendResponse(connection: NWConnection, statusCode: Int, body: String) async {
        let statusText = getStatusText(statusCode)
        let statusLine = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        let headers = "Content-Type: text/plain\r\n" +
                     "Content-Length: \(body.utf8.count)\r\n" +
                     "Connection: close\r\n" +
                     "\r\n"

        let response = statusLine + headers + body

        if let responseData = response.data(using: .utf8) {
            await sendData(connection: connection, data: responseData)
        }
    }

    private func sendData(connection: NWConnection, data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    print("❌ HTTP send error: \(error)")
                }
                continuation.resume()
            })
        }
    }

    private func getStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }

    func stop() async {
        isRunning = false

        // Cancel all connection tasks
        for task in connectionTasks {
            task.cancel()
        }
        connectionTasks.removeAll()

        await listener?.close()
        listener = nil

        print("🛑 HTTP server stopped")
    }
}
