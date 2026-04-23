import Foundation

private extension String {
    init?(posixCString ptr: UnsafePointer<CChar>) {
        let len = strlen(ptr)
        let bytes = UnsafeRawPointer(ptr).withMemoryRebound(to: UInt8.self, capacity: len) {
            UnsafeBufferPointer(start: $0, count: len)
        }
        guard let s = String(validating: bytes, as: UTF8.self) else { return nil }
        self = s
    }
}

struct NetworkHelper {
    static func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else { return addresses }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            guard let interface = ptr?.pointee else { continue }
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                guard let name = String(posixCString: interface.ifa_name) else { continue }

                // Skip loopback and non-active interfaces
                guard !name.starts(with: "lo") else { continue }

                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                             &hostname, socklen_t(hostname.count),
                             nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                    guard let address = hostname.withUnsafeBufferPointer({ buf -> String? in
                        guard let base = buf.baseAddress else { return nil }
                        return String(posixCString: base)
                    }) else { continue }

                    // Only include IPv4 addresses
                    if addrFamily == UInt8(AF_INET) {
                        addresses.append("\(name): \(address)")
                    }
                }
            }
        }

        return addresses
    }
}
