import AppKit
import Foundation
import TailscaleKit

/// Metadata about a Cuple screen share
struct CupleMetadata: Codable, Sendable {
    var version: String = "1.0"
    let shareName: String
    let hostname: String
    let screenResolution: ScreenResolution
    let isSharing: Bool
    let timestamp: Date

    struct ScreenResolution: Codable, Sendable {
        let width: Int
        let height: Int
    }
}

/// Request types for peer-to-peer communication
enum CupleRequest: Codable, Sendable {
    case requestToShare(from: String)
    case acceptShare
    case declineShare

    enum CodingKeys: String, CodingKey {
        case type, from
    }

    enum RequestType: String, Codable {
        case requestToShare
        case acceptShare
        case declineShare
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(RequestType.self, forKey: .type)

        switch type {
        case .requestToShare:
            let from = try container.decode(String.self, forKey: .from)
            self = .requestToShare(from: from)
        case .acceptShare:
            self = .acceptShare
        case .declineShare:
            self = .declineShare
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .requestToShare(let from):
            try container.encode(RequestType.requestToShare, forKey: .type)
            try container.encode(from, forKey: .from)
        case .acceptShare:
            try container.encode(RequestType.acceptShare, forKey: .type)
        case .declineShare:
            try container.encode(RequestType.declineShare, forKey: .type)
        }
    }
}

/// Service for managing Cuple metadata and requests
@MainActor
class CupleMetadataService: ObservableObject {
    @Published var currentMetadata: CupleMetadata?
    @Published var pendingRequests: [PendingRequest] = []

    struct PendingRequest: Identifiable {
        let id = UUID()
        let fromHostname: String
        let timestamp: Date
    }

    /// Get current screen resolution
    private func getCurrentScreenResolution() -> CupleMetadata.ScreenResolution {
        guard let screen = NSScreen.main else {
            return CupleMetadata.ScreenResolution(width: 1920, height: 1080)
        }

        let frame = screen.frame
        return CupleMetadata.ScreenResolution(
            width: Int(frame.width),
            height: Int(frame.height)
        )
    }

    /// Update metadata when sharing starts
    func updateMetadata(isSharing: Bool, shareName: String? = nil) {
        let hostname = Host.current().localizedName ?? "Unknown"
        let name = shareName ?? "\(hostname)'s Screen"

        currentMetadata = CupleMetadata(
            shareName: name,
            hostname: hostname,
            screenResolution: getCurrentScreenResolution(),
            isSharing: isSharing,
            timestamp: Date()
        )
    }

    /// Handle incoming request to share
    func handleRequestToShare(from hostname: String) {
        let request = PendingRequest(fromHostname: hostname, timestamp: Date())
        pendingRequests.append(request)
    }

    /// Clear a pending request
    func clearRequest(_ request: PendingRequest) {
        pendingRequests.removeAll { $0.id == request.id }
    }

    /// Clear all pending requests
    func clearAllRequests() {
        pendingRequests.removeAll()
    }

    /// Create metadata JSON for API response
    func getMetadataJSON() throws -> Data {
        guard let metadata = currentMetadata else {
            throw NSError(
                domain: "CupleMetadata", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No metadata available"])
        }
        return try JSONEncoder().encode(metadata)
    }

    /// Send a request to share to a peer
    func sendRequestToShare(to host: String, port: UInt16 = 7447, from hostname: String)
        async throws
    {
        let url = URL(string: "http://\(host):\(port)/api/request")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let cupleRequest = CupleRequest.requestToShare(from: hostname)
        request.httpBody = try JSONEncoder().encode(cupleRequest)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw NSError(
                domain: "CupleMetadata", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to send request"])
        }
    }

    /// Fetch metadata from a peer over the Tailscale network.
    /// Uses TailscaleKit's OutgoingConnection so the request actually routes via tsnet.
    static func fetchMetadata(
        node: TailscaleNode,
        from host: String,
        port: UInt16 = 7448
    ) async throws -> CupleMetadata {
        guard let tailscaleHandle = await node.tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        let connection = try await OutgoingConnection(
            tailscale: tailscaleHandle,
            to: "\(host):\(port)",
            proto: .tcp,
            logger: MetadataLogger()
        )
        try await connection.connect()

        // Send HTTP/1.0 GET request (HTTP/1.0 so server can close after response)
        let httpRequest =
            "GET /api/metadata HTTP/1.0\r\n"
            + "Host: \(host):\(port)\r\n"
            + "Accept: application/json\r\n"
            + "Connection: close\r\n"
            + "\r\n"

        guard let requestData = httpRequest.data(using: .utf8) else {
            throw NSError(
                domain: "CupleMetadata", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode request"])
        }

        try await connection.send(requestData)

        // Read response until connection closes or we have the whole body.
        var buffer = Data()
        let deadline = Date().addingTimeInterval(5.0)

        while Date() < deadline {
            do {
                let chunk = try await connection.receive(maximumLength: 8192, timeout: 2_000)
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if buffer.count > 64 * 1024 { break }  // metadata is small; bail on bloat
            } catch {
                break  // EOF or timeout — use what we have
            }
        }

        await connection.close()

        // Split headers from body on the blank line.
        guard let separator = "\r\n\r\n".data(using: .utf8),
              let range = buffer.range(of: separator)
        else {
            throw NSError(
                domain: "CupleMetadata", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Malformed HTTP response"])
        }

        let headerData = buffer[..<range.lowerBound]
        let body = buffer[range.upperBound...]

        guard let headerString = String(data: headerData, encoding: .utf8),
              let statusLine = headerString.components(separatedBy: "\r\n").first
        else {
            throw NSError(
                domain: "CupleMetadata", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP headers"])
        }

        let parts = statusLine.components(separatedBy: " ")
        guard parts.count >= 2, let status = Int(parts[1]), (200...299).contains(status) else {
            throw NSError(
                domain: "CupleMetadata", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "HTTP error: \(statusLine)"])
        }

        return try JSONDecoder().decode(CupleMetadata.self, from: body)
    }
}

private struct MetadataLogger: LogSink {
    var logFileHandle: Int32? = nil
    func log(_ message: String) {
        // Quiet by default; metadata fetches happen often.
    }
}
