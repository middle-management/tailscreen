# Tailscale Integration - Quick Start Guide

A minimal guide to get started with Tailscale networking in Cuple using the **official TailscaleKit framework**.

## TL;DR

```bash
# 1. Clone and build TailscaleKit framework
cd /tmp
git clone https://github.com/tailscale/libtailscale.git
cd libtailscale/swift
make macos  # Builds TailscaleKit.framework

# 2. Add framework to your Xcode project
# Drag TailscaleKit.framework into your project

# 3. Get an auth key from Tailscale
open https://login.tailscale.com/admin/settings/keys

# 4. Set it as environment variable
export TS_AUTHKEY="tskey-auth-xxxxxxxxxxxxx"

# 5. Use TailscaleKit in your app!
```

## What's TailscaleKit?

TailscaleKit is the **official Swift framework** from Tailscale (found in `libtailscale/swift/`). It provides:

- ✅ Native Swift API with async/await
- ✅ Swift 6 concurrency compliance
- ✅ Actor-based thread safety
- ✅ Modern API design
- ✅ LocalAPI client for Tailnet state
- ✅ URLSession extensions for HTTP/HTTPS

## Code Examples

### Server Example

```swift
import TailscaleKit

let server = TailscaleScreenShareServer()

Task {
    do {
        // Start server (uses TS_AUTHKEY from environment if not specified)
        try await server.start(hostname: "my-mac")

        // Print Tailscale IPs
        let ips = try await server.getIPAddresses()
        print("✅ Server running on:")
        print("   IPv4: \(ips.ip4 ?? "none")")
        print("   IPv6: \(ips.ip6 ?? "none")")
        print("📱 Others can connect using: my-mac")

    } catch {
        print("❌ Server failed: \(error)")
    }
}

// Stop when done
await server.stop()
```

### Client Example

```swift
import TailscaleKit

let client = TailscaleScreenShareClient()

Task {
    do {
        // Connect to server by hostname
        try await client.connect(to: "my-mac", port: 7447)

        print("✅ Connected! Video window will appear automatically.")

    } catch {
        print("❌ Connection failed: \(error)")
    }
}

// Disconnect when done
await client.disconnect()
```

## Building TailscaleKit

### Step 1: Clone the Repository

```bash
cd /tmp
git clone https://github.com/tailscale/libtailscale.git
cd libtailscale/swift
```

### Step 2: Build the Framework

```bash
# For macOS (creates TailscaleKit.framework)
make macos

# For iOS (creates fat framework with simulator + device)
make ios-fat

# For iOS Simulator only
make ios-sim

# See all options
make help
```

The built framework will be in `build/macos/TailscaleKit.framework` (or respective platform directory).

### Step 3: Add to Xcode Project

1. **Drag and drop** `TailscaleKit.framework` into your Xcode project navigator
2. In **Build Phases** → **Embed Frameworks**, ensure TailscaleKit is listed
3. In **General** → **Frameworks, Libraries, and Embedded Content**, verify it's set to "Embed & Sign"

That's it! No bridging headers, no C API bindings needed. Just import and use:

```swift
import TailscaleKit
```

## Getting an Auth Key

1. Visit: https://login.tailscale.com/admin/settings/keys
2. Click "Generate auth key"
3. Check "Ephemeral" (recommended for temporary sharing sessions)
4. Copy the key
5. Export it:

```bash
export TS_AUTHKEY="tskey-auth-xxxxxxxxxxxxx"
```

Or pass it directly in code:

```swift
try await server.start(hostname: "my-mac", authKey: "tskey-auth-xxx...")
```

## Comparison: TailscaleKit vs Raw TCP

| Feature | Raw TCP | TailscaleKit |
|---------|---------|--------------|
| **Setup** | Simple | Single framework import |
| **Encryption** | None | WireGuard (built-in) |
| **Auth** | Manual IP sharing | Tailscale identity |
| **NAT Traversal** | Manual forwarding | Automatic |
| **Cross-network** | Requires public IP | Works everywhere |
| **Code complexity** | Low | Low (official API) |
| **Peer discovery** | Manual | Via Tailnet |

## Architecture

```
┌─────────────────────────────────┐
│   Your Cuple App                │
├─────────────────────────────────┤
│   TailscaleScreenShareServer    │
│   TailscaleScreenShareClient    │
├─────────────────────────────────┤
│   TailscaleKit.framework        │  ← Official Swift framework
│   (TailscaleNode, Listener,     │
│    OutgoingConnection, etc.)    │
├─────────────────────────────────┤
│   libtailscale.a (C library)    │  ← Compiled into framework
├─────────────────────────────────┤
│   Tailscale/WireGuard           │
└─────────────────────────────────┘
```

## API Overview

### TailscaleNode (Actor)

Main entry point for creating a Tailscale node:

```swift
let config = Configuration(
    hostName: "my-app",
    path: "/path/to/state",
    authKey: "tskey-auth-...",
    controlURL: kDefaultControlURL,
    ephemeral: true
)

let node = try TailscaleNode(config: config, logger: logger)
try await node.up()

let ips = try await node.addrs()  // Returns (ip4: String?, ip6: String?)
```

### Listener (Actor)

Accept incoming connections:

```swift
let listener = try await Listener(
    tailscale: node.tailscale!,
    proto: .tcp,
    address: ":7447",
    logger: logger
)

let connection = try await listener.accept(timeout: 60.0)
let data = try await connection.receive(maximumLength: 4096, timeout: 1000)
```

### OutgoingConnection (Actor)

Create outgoing connections:

```swift
let connection = try await OutgoingConnection(
    tailscale: node.tailscale!,
    to: "peer-hostname:7447",
    proto: .tcp,
    logger: logger
)

try await connection.connect()
try connection.send(myData)
```

### URLSession Extension

For HTTP/HTTPS, use the URLSession extension:

```swift
let (sessionConfig, _) = try await URLSessionConfiguration.tailscaleSession(node)
let session = URLSession(configuration: sessionConfig)

let url = URL(string: "http://peer-hostname/api")!
let (data, _) = try await session.data(from: url)
```

## Next Steps

1. ✅ Build TailscaleKit.framework
2. ✅ Add it to your Xcode project
3. ✅ Get a Tailscale auth key
4. ✅ Import TailscaleKit in your code
5. ✅ Use TailscaleScreenShareServer and TailscaleScreenShareClient

## Known Limitations

The current implementation has a few architectural considerations:

1. **Bidirectional Communication**: TailscaleKit's `OutgoingConnection` only supports sending data (no `receive()` method). For bidirectional communication, you would need to:
   - Use separate Listener for server→client direction
   - Or access the underlying file descriptor directly
   - Or extend TailscaleKit to add receiving capabilities

2. **Connection Broadcasting**: The server needs to send H.264 frames to multiple clients. The current `IncomingConnection` API doesn't expose a `send()` method, so broadcasting would require accessing raw file descriptors.

These are framework design choices and can be addressed by either extending TailscaleKit or using the underlying C API directly for specific use cases.

## Troubleshooting

### "Module 'TailscaleKit' not found"

- Ensure the framework is in your project
- Check Build Phases → Link Binary With Libraries
- Verify framework search paths

### "No such module 'TailscaleKit'"

- Clean build folder (Cmd+Shift+K)
- Rebuild the framework
- Restart Xcode

### "dyld: Library not loaded: TailscaleKit.framework"

- Check that framework is set to "Embed & Sign" in General → Frameworks
- Verify it's in Build Phases → Embed Frameworks

### Connection fails

- Verify both nodes are authenticated to Tailscale
- Check Tailscale status: `tailscale status`
- Ensure ACLs allow traffic on the port
- Try connecting by IP instead of hostname

## Resources

- [TailscaleKit Source](https://github.com/tailscale/libtailscale/tree/main/swift)
- [TailscaleKit Example](https://github.com/tailscale/libtailscale/tree/main/swift/Examples/TailscaleKitHello)
- [Tailscale Docs](https://tailscale.com/kb/)
- [libtailscale README](https://github.com/tailscale/libtailscale)

## Full Documentation

See [TAILSCALE_INTEGRATION.md](./TAILSCALE_INTEGRATION.md) for comprehensive documentation.
