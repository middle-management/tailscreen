import Foundation
import AppKit

/// Metadata about a Cuple screen share
struct CupleMetadata: Codable, Sendable {
    let version: String = "1.0"
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
            throw NSError(domain: "CupleMetadata", code: 1, userInfo: [NSLocalizedDescriptionKey: "No metadata available"])
        }
        return try JSONEncoder().encode(metadata)
    }

    /// Send a request to share to a peer
    func sendRequestToShare(to host: String, port: UInt16 = 7447, from hostname: String) async throws {
        let url = URL(string: "http://\(host):\(port)/api/request")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let cupleRequest = CupleRequest.requestToShare(from: hostname)
        request.httpBody = try JSONEncoder().encode(cupleRequest)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "CupleMetadata", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to send request"])
        }
    }

    /// Fetch metadata from a peer
    static func fetchMetadata(from host: String, port: UInt16 = 7448) async throws -> CupleMetadata {
        let url = URL(string: "http://\(host):\(port)/api/metadata")!

        // Create request with timeout
        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "CupleMetadata", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch metadata"])
        }

        return try JSONDecoder().decode(CupleMetadata.self, from: data)
    }
}
