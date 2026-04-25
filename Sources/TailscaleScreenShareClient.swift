import AppKit
import CoreVideo
import Foundation
import TailscaleKit

/// Screen-share viewer. Dials a peer over TailscaleKit, parses the framed
/// protocol, decodes H.264 via `VideoDecoder` (VTDecompressionSession), and
/// hands the resulting `CVPixelBuffer`s to a shared `MetalViewerRenderer`.
///
/// The renderer (and the `NSWindow` it lives in) is owned by `AppState` for
/// the process lifetime. The client never creates or destroys either: every
/// `NSWindow.close()` ordering we tried raced something in the AppKit/CA
/// teardown chain (autoreleased IOSurfaces / CVPixelBufferPool releases land
/// in the same main-queue pool a Swift `Task` is about to pop, SIGSEGV in
/// `objc_release`). Keeping the window alive and only `orderOut`-ing it on
/// disconnect sidesteps the race entirely.
@available(macOS 10.15, *)
final class TailscaleScreenShareClient: @unchecked Sendable {
    var node: TailscaleNode?

    private var connection: OutgoingConnection?
    private let renderer: MetalViewerRenderer
    private var decoder: VideoDecoder?
    private var isConnected = false
    private var isDisconnecting = false
    private let logger: TSLogger
    private var receiveTask: Task<Void, Never>?

    init(renderer: MetalViewerRenderer) {
        self.renderer = renderer
        self.logger = TSLogger()
    }

    func connect(to hostname: String, port: UInt16 = 7447, authKey: String? = nil, path: String? = nil) async throws {
        guard !isConnected else { return }

        let statePath = path ?? {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return appSupport.appendingPathComponent("Cuple/tailscale-client\(CupleInstance.stateSuffix)").path
        }()
        try? FileManager.default.createDirectory(atPath: statePath, withIntermediateDirectories: true)

        print("Starting Tailscale client…")

        let clientHostname = "cuple-client-\(UUID().uuidString.prefix(8))"
        let config = Configuration(
            hostName: clientHostname,
            path: statePath,
            authKey: authKey,
            controlURL: kDefaultControlURL,
            ephemeral: true
        )

        let node = try TailscaleNode(config: config, logger: logger)
        self.node = node
        try await node.up()

        let ips = try await node.addrs()
        print("Tailscale connected — ip4=\(ips.ip4 ?? "-") ip6=\(ips.ip6 ?? "-")")

        guard let tailscaleHandle = await node.tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        print("Dialing \(hostname):\(port)…")
        let connection = try await OutgoingConnection(
            tailscale: tailscaleHandle,
            to: "\(hostname):\(port)",
            proto: .tcp,
            logger: logger
        )
        try await connection.connect()
        self.connection = connection

        let decoder = VideoDecoder()
        decoder.onDecodedFrame = { [weak self] pixelBuffer in
            self?.handleDecodedFrame(pixelBuffer)
        }
        self.decoder = decoder

        self.isConnected = true
        print("Connected to \(hostname)")

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        guard let connection = connection else { return }
        var parser = ScreenShareMessageParser()
        var bytesReceived = 0
        var framesReceived = 0

        while isConnected {
            do {
                // Generous timeout so we don't spin; receive returns as soon as bytes arrive.
                let chunk = try await connection.receive(maximumLength: 64 * 1024, timeout: 5_000)
                if chunk.isEmpty { continue }
                bytesReceived += chunk.count

                parser.append(chunk)
                while let message = parser.next() {
                    switch message {
                    case .parameterSets(let sps, let pps):
                        print("Client: received SPS/PPS (sps=\(sps.count)B pps=\(pps.count)B)")
                        decoder?.setParameterSets(sps: sps, pps: pps)
                    case .frame(let data, let isKeyframe, let timestampNs):
                        framesReceived += 1
                        if framesReceived == 1 || framesReceived % 60 == 0 {
                            let nowNs = DispatchTime.now().uptimeNanoseconds
                            let latencyMs: Double
                            if timestampNs > 0 && nowNs >= timestampNs {
                                latencyMs = Double(nowNs - timestampNs) / 1_000_000.0
                            } else {
                                latencyMs = -1
                            }
                            let latencyStr = latencyMs >= 0 ? String(format: "%.1fms", latencyMs) : "n/a"
                            print("Client: received frame #\(framesReceived) (kf=\(isKeyframe), \(data.count)B, total=\(bytesReceived)B, encode→recv=\(latencyStr))")
                        }
                        self.lastReceiveUptimeNs = DispatchTime.now().uptimeNanoseconds
                        decoder?.decode(data: data, isKeyframe: isKeyframe)
                    }
                }
            } catch TailscaleError.readFailed {
                if !isConnected { break }
                continue
            } catch {
                if isConnected {
                    print("Receive error: \(error)")
                }
                break
            }
        }
    }

    /// Timestamp (mach uptime ns) when the most recent frame finished
    /// arriving on the socket. Used only to measure recv→present latency;
    /// last-writer-wins is fine for that purpose.
    private var lastReceiveUptimeNs: UInt64 = 0

    private func handleDecodedFrame(_ buffer: CVPixelBuffer) {
        // VTDecompressionSession delivers frames on its own callback thread.
        // The renderer guards its pending-frame slot with a lock, so handing
        // the buffer over from any thread is safe.
        guard isConnected, !isDisconnecting else { return }
        renderer.setPixelBuffer(buffer, receiveUptimeNs: lastReceiveUptimeNs)
    }

    func disconnect() async {
        // Idempotent. Disconnect can fire from the menu's Disconnect button
        // and the receiveLoop's error path concurrently during teardown.
        if isDisconnecting { return }
        isDisconnecting = true

        isConnected = false

        // Stop the receive loop and wait for it to exit BEFORE closing the
        // Tailscale node. Closing the node rips the underlying fd out from
        // under a concurrent read and segfaults tsnet.
        if let receiveTask = receiveTask {
            receiveTask.cancel()
            _ = await receiveTask.value
        }
        receiveTask = nil

        if let connection = connection {
            await connection.close()
            self.connection = nil
        }

        if let node = node {
            try? await node.close()
            self.node = nil
        }

        // Shut the decoder down last. `shutdown` drains via
        // `WaitForAsynchronousFrames` and blocks on the decoder's serial
        // queue, so once it returns no more frames can be delivered to the
        // renderer.
        if let decoder = decoder {
            decoder.onDecodedFrame = nil
            decoder.shutdown()
            self.decoder = nil
        }

        // No window/renderer teardown here — both are app-lifetime singletons
        // owned by AppState. AppState.disconnect handles orderOut + clearing
        // the renderer's pending frame.
        print("Client disconnected")
    }

    deinit {
        isConnected = false
        receiveTask?.cancel()
    }
}

private struct TSLogger: LogSink {
    var logFileHandle: Int32? = nil
    func log(_ message: String) { print("[Tailscale] \(message)") }
}
