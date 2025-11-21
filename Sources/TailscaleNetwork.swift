import Foundation
import Network

// MARK: - C API Declarations
// These declarations match the libtailscale C API
// In a real implementation, these would come from a bridging header

typealias TailscaleServer = OpaquePointer
typealias TailscaleConn = Int32

// Placeholder C function declarations - these would normally be in tailscale.h
// In production, you'd import these via a module map or bridging header
@_silgen_name("tailscale_new")
func tailscale_new() -> TailscaleServer?

@_silgen_name("tailscale_set_dir")
func tailscale_set_dir(_ server: TailscaleServer, _ dir: UnsafePointer<CChar>)

@_silgen_name("tailscale_set_hostname")
func tailscale_set_hostname(_ server: TailscaleServer, _ hostname: UnsafePointer<CChar>)

@_silgen_name("tailscale_set_authkey")
func tailscale_set_authkey(_ server: TailscaleServer, _ authkey: UnsafePointer<CChar>)

@_silgen_name("tailscale_set_ephemeral")
func tailscale_set_ephemeral(_ server: TailscaleServer, _ ephemeral: Int32)

@_silgen_name("tailscale_up")
func tailscale_up(_ server: TailscaleServer) -> Int32

@_silgen_name("tailscale_start")
func tailscale_start(_ server: TailscaleServer) -> Int32

@_silgen_name("tailscale_close")
func tailscale_close(_ server: TailscaleServer)

@_silgen_name("tailscale_dial")
func tailscale_dial(_ server: TailscaleServer, _ network: UnsafePointer<CChar>, _ address: UnsafePointer<CChar>) -> TailscaleConn

@_silgen_name("tailscale_listen")
func tailscale_listen(_ server: TailscaleServer, _ network: UnsafePointer<CChar>, _ address: UnsafePointer<CChar>) -> TailscaleConn

@_silgen_name("tailscale_accept")
func tailscale_accept(_ listener: TailscaleConn) -> TailscaleConn

@_silgen_name("tailscale_errmsg")
func tailscale_errmsg(_ server: TailscaleServer) -> UnsafePointer<CChar>?

@_silgen_name("tailscale_getips")
func tailscale_getips(_ server: TailscaleServer) -> UnsafePointer<CChar>?

// MARK: - Swift Wrapper

enum TailscaleError: Error {
    case initializationFailed
    case startFailed(String)
    case dialFailed(String)
    case listenFailed(String)
    case acceptFailed(String)
    case notStarted
    case invalidFileDescriptor
}

/// Swift wrapper for Tailscale networking using libtailscale
@available(macOS 10.15, *)
class TailscaleNetwork {
    private var server: TailscaleServer?
    private let stateDirectory: String
    private let hostname: String
    private var isStarted = false

    /// Initialize a new Tailscale network instance
    /// - Parameters:
    ///   - hostname: The hostname for this Tailscale node
    ///   - stateDirectory: Directory to store Tailscale state (default: ~/Library/Application Support/Cuple/tailscale)
    init(hostname: String, stateDirectory: String? = nil) {
        self.hostname = hostname

        // Default state directory
        if let stateDir = stateDirectory {
            self.stateDirectory = stateDir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.stateDirectory = appSupport.appendingPathComponent("Cuple/tailscale").path
        }

        // Create state directory if it doesn't exist
        try? FileManager.default.createDirectory(atPath: self.stateDirectory, withIntermediateDirectories: true)
    }

    /// Start the Tailscale network and connect to the tailnet
    /// - Parameter authKey: Optional auth key for automatic authentication (defaults to TS_AUTHKEY env var)
    /// - Parameter ephemeral: If true, this node will be removed when it goes offline
    func start(authKey: String? = nil, ephemeral: Bool = false) async throws {
        guard !isStarted else { return }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                // Create server
                guard let server = tailscale_new() else {
                    continuation.resume(throwing: TailscaleError.initializationFailed)
                    return
                }
                self.server = server

                // Configure server
                self.stateDirectory.withCString { dirPtr in
                    tailscale_set_dir(server, dirPtr)
                }

                self.hostname.withCString { hostnamePtr in
                    tailscale_set_hostname(server, hostnamePtr)
                }

                // Set auth key if provided, otherwise will use TS_AUTHKEY env var
                if let authKey = authKey {
                    authKey.withCString { authKeyPtr in
                        tailscale_set_authkey(server, authKeyPtr)
                    }
                }

                tailscale_set_ephemeral(server, ephemeral ? 1 : 0)

                // Start and wait for connection
                let result = tailscale_up(server)

                if result == 0 {
                    self.isStarted = true
                    continuation.resume()
                } else {
                    let errorMsg = self.getErrorMessage() ?? "Unknown error"
                    continuation.resume(throwing: TailscaleError.startFailed(errorMsg))
                }
            }
        }
    }

    /// Get the Tailscale IP addresses assigned to this node
    func getIPAddresses() -> [String] {
        guard let server = server else { return [] }

        guard let ipsPtr = tailscale_getips(server) else {
            return []
        }

        let ipsString = String(cString: ipsPtr)
        return ipsString.split(separator: ",").map(String.init)
    }

    /// Connect to a peer on the tailnet
    /// - Parameters:
    ///   - host: Hostname or IP address of the peer
    ///   - port: Port number to connect to
    /// - Returns: FileHandle for the connection
    func dial(host: String, port: UInt16) async throws -> FileHandle {
        guard isStarted, let server = server else {
            throw TailscaleError.notStarted
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let address = "\(host):\(port)"
                let fd = "tcp".withCString { networkPtr in
                    address.withCString { addressPtr in
                        tailscale_dial(server, networkPtr, addressPtr)
                    }
                }

                if fd < 0 {
                    let errorMsg = self.getErrorMessage() ?? "Connection failed"
                    continuation.resume(throwing: TailscaleError.dialFailed(errorMsg))
                } else {
                    continuation.resume(returning: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
                }
            }
        }
    }

    /// Listen for incoming connections on the tailnet
    /// - Parameter port: Port number to listen on
    /// - Returns: TailscaleListener for accepting connections
    func listen(port: UInt16) throws -> TailscaleListener {
        guard isStarted, let server = server else {
            throw TailscaleError.notStarted
        }

        let address = ":\(port)"
        let listenerFd = "tcp".withCString { networkPtr in
            address.withCString { addressPtr in
                tailscale_listen(server, networkPtr, addressPtr)
            }
        }

        if listenerFd < 0 {
            let errorMsg = getErrorMessage() ?? "Listen failed"
            throw TailscaleError.listenFailed(errorMsg)
        }

        return TailscaleListener(listenerFd: listenerFd, tailscale: self)
    }

    /// Internal method to accept a connection
    fileprivate func accept(listenerFd: TailscaleConn) throws -> FileHandle {
        let connFd = tailscale_accept(listenerFd)

        if connFd < 0 {
            let errorMsg = getErrorMessage() ?? "Accept failed"
            throw TailscaleError.acceptFailed(errorMsg)
        }

        return FileHandle(fileDescriptor: connFd, closeOnDealloc: true)
    }

    private func getErrorMessage() -> String? {
        guard let server = server else { return nil }
        guard let errPtr = tailscale_errmsg(server) else { return nil }
        return String(cString: errPtr)
    }

    /// Stop the Tailscale network
    func stop() {
        if let server = server {
            tailscale_close(server)
            self.server = nil
            isStarted = false
        }
    }

    deinit {
        stop()
    }
}

/// Listener for accepting incoming Tailscale connections
class TailscaleListener {
    private let listenerFd: TailscaleConn
    private weak var tailscale: TailscaleNetwork?
    private var isListening = true

    fileprivate init(listenerFd: TailscaleConn, tailscale: TailscaleNetwork) {
        self.listenerFd = listenerFd
        self.tailscale = tailscale
    }

    /// Accept an incoming connection
    /// - Returns: FileHandle for the accepted connection
    func accept() async throws -> FileHandle {
        guard isListening else {
            throw TailscaleError.listenFailed("Listener closed")
        }

        guard let tailscale = tailscale else {
            throw TailscaleError.notStarted
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let handle = try tailscale.accept(listenerFd: self.listenerFd)
                    continuation.resume(returning: handle)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Close the listener
    func close() {
        isListening = false
        Darwin.close(listenerFd)
    }

    deinit {
        close()
    }
}

// MARK: - NWConnection Bridge (Optional)

@available(macOS 10.15, *)
extension TailscaleNetwork {
    /// Create an NWConnection from a Tailscale FileHandle
    /// This bridges Tailscale connections to Apple's Network framework
    func createConnection(to host: String, port: UInt16) async throws -> NWConnection {
        let fileHandle = try await dial(host: host, port: port)

        // Create NWConnection from file descriptor
        // Note: This requires creating a custom NWProtocolFramer or using TCP directly
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
        let connection = NWConnection(to: endpoint, using: .tcp)

        // TODO: Bridge the file descriptor to NWConnection
        // This is a simplified version - production code would need to handle data transfer

        return connection
    }
}
