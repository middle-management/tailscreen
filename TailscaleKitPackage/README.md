# TailscaleKit Swift Package

A Swift Package wrapping the official [TailscaleKit](https://github.com/tailscale/libtailscale/tree/main/swift) framework from Tailscale's libtailscale repository.

This package provides a clean, reusable Swift Package Manager integration for TailscaleKit, making it easy to add Tailscale networking to any Swift project without requiring Xcode.

## Features

✅ **Official TailscaleKit** - Uses the official Swift framework from Tailscale
✅ **Swift Package Manager** - Standard SPM package structure
✅ **Git Submodule** - Tracks upstream libtailscale directly
✅ **No Xcode Required** - Build with command-line Swift tools
✅ **Easy Updates** - Update to latest Tailscale with one command
✅ **Actor-based** - Swift 6 concurrency compliant

## Quick Start

### 1. Clone with Submodules

```bash
git clone --recurse-submodules <your-repo-url>
cd TailscaleKitPackage
```

Or if already cloned:

```bash
git submodule update --init --recursive
```

### 2. Build the C Library

```bash
./setup.sh
```

This will:
- Build the C library (requires Go)
- Verify symlinks are in place

**Note**: Swift sources are symlinked from `upstream/libtailscale/swift/TailscaleKit/`, so no copying is needed!

### 3. Build

```bash
swift build
```

### 4. Use in Your Project

Add to your `Package.swift`:

```swift
.package(path: "../TailscaleKitPackage")
```

Or as a git dependency (if you host this package):

```swift
.package(url: "https://github.com/yourusername/TailscaleKitPackage", branch: "main")
```

Then add the dependency to your target:

```swift
.target(
    name: "YourApp",
    dependencies: ["TailscaleKit"]
)
```

## Usage Example

```swift
import TailscaleKit

// Create configuration
let config = Configuration(
    hostName: "my-app",
    path: "/path/to/state",
    authKey: "tskey-auth-...",
    controlURL: kDefaultControlURL,
    ephemeral: true
)

// Create logger
struct MyLogger: LogSink {
    var logFileHandle: Int32? = nil
    func log(_ message: String) {
        print("[Tailscale] \(message)")
    }
}

// Start Tailscale node
let node = try TailscaleNode(config: config, logger: MyLogger())
try await node.up()

// Get IP addresses
let ips = try await node.addrs()
print("IPv4: \(ips.ip4 ?? "none")")
print("IPv6: \(ips.ip6 ?? "none")")

// Listen for connections
let listener = try await Listener(
    tailscale: node.tailscale!,
    proto: .tcp,
    address: ":8080",
    logger: MyLogger()
)

let connection = try await listener.accept(timeout: 60.0)
let data = try await connection.receive(maximumLength: 4096, timeout: 1000)

// Or connect to a peer
let outgoing = try await OutgoingConnection(
    tailscale: node.tailscale!,
    to: "peer:8080",
    proto: .tcp,
    logger: MyLogger()
)

try await outgoing.connect()
try outgoing.send(myData)
```

## API Overview

### TailscaleNode (Actor)

Main entry point for creating a Tailscale node:

- `init(config:logger:)` - Create and start a node
- `up()` - Bring the node up
- `down()` - Take the node down
- `addrs()` - Get IPv4 and IPv6 addresses
- `loopback()` - Start SOCKS5 proxy and LocalAPI server
- `close()` - Stop the node

### Listener (Actor)

Accept incoming connections:

- `init(tailscale:proto:address:logger:)` - Create listener
- `accept(timeout:)` - Accept incoming connection
- `close()` - Close listener

### OutgoingConnection (Actor)

Create outgoing connections:

- `init(tailscale:to:proto:logger:)` - Create connection
- `connect()` - Connect to peer
- `send(_:)` - Send data
- `close()` - Close connection

### IncomingConnection (Actor)

Handle accepted connections:

- `receive(maximumLength:timeout:)` - Receive data
- `receiveMessage(timeout:)` - Receive complete message
- `close()` - Close connection

### URLSession Extension

For HTTP/HTTPS requests:

```swift
let (sessionConfig, _) = try await URLSessionConfiguration.tailscaleSession(node)
let session = URLSession(configuration: sessionConfig)
let (data, _) = try await session.data(from: url)
```

## Directory Structure

```
TailscaleKitPackage/
├── Package.swift              # Swift Package definition
├── setup.sh                   # Build script (only builds C library)
├── README.md                  # This file
├── Sources/
│   └── TailscaleKit/         # Symlink → upstream/libtailscale/swift/TailscaleKit/
├── Tests/
│   └── TailscaleKitTests/    # Unit tests
├── Modules/
│   └── libtailscale/
│       └── module.modulemap   # C library module map
├── lib/
│   └── libtailscale.a        # Symlink → upstream/libtailscale/libtailscale.a
├── include/
│   └── tailscale.h           # Symlink → upstream/libtailscale/tailscale.h
└── upstream/
    └── libtailscale/         # Git submodule (official Tailscale source)
        ├── swift/TailscaleKit/  # Original Swift sources
        ├── tailscale.h          # Original C header
        └── libtailscale.a       # Built by `make c-archive`
```

**Note**: `Sources/`, `lib/`, and `include/` are symlinks, not copies. Changes in upstream are immediately reflected!

## Updating TailscaleKit

To update to the latest version of TailscaleKit:

```bash
./setup.sh --update
```

This will:
1. Update the libtailscale submodule to the latest commit
2. Rebuild the C library
3. Copy updated Swift sources

Or manually:

```bash
cd upstream/libtailscale
git pull origin main
cd ../..
./setup.sh
```

## Requirements

- **Swift 5.9+**
- **Go 1.21+** (for building libtailscale.a)
- **macOS 13+** or **iOS 16+**

## Building for Different Platforms

### macOS

```bash
./setup.sh
swift build
```

### iOS

The C library needs to be built for iOS:

```bash
cd upstream/libtailscale
make c-archive-ios  # For device
# or
make c-archive-ios-sim  # For simulator
```

Then copy the appropriate library:

```bash
cp upstream/libtailscale/libtailscale_ios.a lib/
# or
cp upstream/libtailscale/libtailscale_ios_sim.a lib/
```

## Testing

```bash
swift test
```

To add tests, create files in `Tests/TailscaleKitTests/`.

## Troubleshooting

### "No such module 'TailscaleKit'"

Run the setup script:

```bash
./setup.sh
```

### "Cannot find 'libtailscale.a'"

The C library hasn't been built. Make sure you have Go installed and run:

```bash
./setup.sh
```

### "Go not found"

Install Go from https://go.dev/dl/

### Submodule not initialized

```bash
git submodule update --init --recursive
```

## License

This package wraps the official TailscaleKit framework from Tailscale. The original code is:

- Copyright (c) Tailscale Inc & AUTHORS
- SPDX-License-Identifier: BSD-3-Clause

See the [upstream repository](https://github.com/tailscale/libtailscale) for full license details.

## Contributing

This is a wrapper package. For issues with TailscaleKit itself, please file issues at:
https://github.com/tailscale/tailscale/issues

For issues with this wrapper package, please file issues in this repository.

## Related Links

- [Tailscale](https://tailscale.com/)
- [libtailscale](https://github.com/tailscale/libtailscale)
- [TailscaleKit Source](https://github.com/tailscale/libtailscale/tree/main/swift)
- [Tailscale Documentation](https://tailscale.com/kb/)
