# Tailscale Integration for Cuple

This document describes how to use Tailscale tsnet for networking and authentication in Cuple.

## Overview

The Tailscale integration provides:

- ✅ **Secure end-to-end encryption** - All traffic is encrypted via WireGuard
- ✅ **Automatic NAT traversal** - Works across different networks without port forwarding
- ✅ **Built-in authentication** - Uses Tailscale identity for access control
- ✅ **Peer discovery** - Find other Cuple nodes automatically on your tailnet
- ✅ **Cross-network sharing** - Share screens across the internet, not just LAN
- ✅ **No manual IP sharing** - Connect using hostnames instead of IP addresses

## Architecture

### Components

1. **TailscaleNetwork.swift** - Swift wrapper for libtailscale C API
2. **TailscaleScreenShareServer.swift** - Server that listens on Tailscale network
3. **TailscaleScreenShareClient.swift** - Client that connects via Tailscale

### How It Works

```
┌─────────────────────┐           Tailscale Network          ┌─────────────────────┐
│  Server (sharing)   │◄──────────────────────────────────►  │  Client (viewing)   │
│                     │         (encrypted mesh)             │                     │
│ • Start tailscale   │                                      │ • Start tailscale   │
│ • Get IP: 100.x.x.1 │                                      │ • Get IP: 100.x.x.2 │
│ • Listen on :7447   │                                      │ • Connect to peer   │
│ • Capture & encode  │──────► H.264 frames ────────────────►│ • Decode & display  │
└─────────────────────┘                                      └─────────────────────┘
```

## Setup Instructions

### Prerequisites

1. **Tailscale Account** - Sign up at [tailscale.com](https://tailscale.com)
2. **Auth Key** (optional but recommended) - Generate at: https://login.tailscale.com/admin/settings/keys
   - For ephemeral nodes, enable "Ephemeral" when creating the key
   - Store securely or set as environment variable: `export TS_AUTHKEY="tskey-auth-..."`

3. **Build libtailscale** - See "Building libtailscale" section below

### Building libtailscale

The integration requires the `libtailscale` C library. Build it as follows:

```bash
# Clone the repository
git clone https://github.com/tailscale/libtailscale.git
cd libtailscale

# Build the static library
make archive

# This creates libtailscale.a and tailscale.h
```

### Linking libtailscale with Cuple

You'll need to link the built library with your Xcode project:

1. **Add the library to your project:**
   - Copy `libtailscale.a` to your project directory (e.g., `lib/libtailscale.a`)
   - Copy `tailscale.h` to your project directory (e.g., `include/tailscale.h`)

2. **Configure Xcode:**
   - Add `libtailscale.a` to "Link Binary With Libraries" in Build Phases
   - Add the `include` directory to "Header Search Paths" in Build Settings
   - Set "Library Search Paths" to include the `lib` directory

3. **Create a bridging header:**
   ```c
   // Cuple-Bridging-Header.h
   #import "tailscale.h"
   ```

4. **Update Build Settings:**
   - Set "Objective-C Bridging Header" to `Cuple-Bridging-Header.h`

**Note:** The current implementation includes placeholder C function declarations using `@_silgen_name`. Replace these with proper imports from the bridging header once libtailscale is linked.

## Usage

### Starting a Server

```swift
let server = TailscaleScreenShareServer()

// Start with automatic auth (uses TS_AUTHKEY env var)
try await server.start(hostname: "my-mac-screen")

// Or with explicit auth key
try await server.start(
    hostname: "my-mac-screen",
    authKey: "tskey-auth-xxxxxxxxxxxxx"
)

// Get Tailscale IPs
let ips = server.getIPAddresses()
print("Share this address: \(ips.first ?? "unknown")")

// Stop server when done
server.stop()
```

### Connecting a Client

```swift
let client = TailscaleScreenShareClient()

// Connect using Tailscale hostname
try await client.connect(to: "my-mac-screen", port: 7447)

// Or connect using Tailscale IP
try await client.connect(to: "100.64.0.1", port: 7447)

// Disconnect when done
client.disconnect()
```

## Authentication Methods

### Method 1: Environment Variable (Recommended for Development)

```bash
export TS_AUTHKEY="tskey-auth-xxxxxxxxxxxxx"
# Run your app - it will automatically use this key
```

### Method 2: Explicit Auth Key

```swift
try await server.start(
    hostname: "my-mac-screen",
    authKey: "tskey-auth-xxxxxxxxxxxxx"
)
```

### Method 3: Interactive Login (No Auth Key)

If no auth key is provided, libtailscale will:
1. Generate a login URL
2. Print it to the console
3. Wait for you to complete authentication in a browser

**Note:** Check console output for the authentication URL when using this method.

## Security Features

### Encryption

All traffic is encrypted using WireGuard protocol:
- End-to-end encryption between peers
- Forward secrecy
- No plaintext transmission

### Access Control

Use Tailscale ACLs to control access:

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["group:admins"],
      "dst": ["tag:cuple-server:7447"]
    }
  ]
}
```

### Ephemeral Nodes

The integration uses ephemeral nodes by default:
- Nodes are automatically removed when they go offline
- No permanent presence in your tailnet
- Ideal for temporary screen sharing sessions

## Comparison: Traditional vs Tailscale

| Feature | Traditional TCP | Tailscale |
|---------|----------------|-----------|
| **Encryption** | None | WireGuard (built-in) |
| **Authentication** | None | Tailscale identity |
| **NAT Traversal** | Manual port forwarding | Automatic |
| **Cross-network** | Requires public IP | Works automatically |
| **Peer Discovery** | Manual IP sharing | Automatic via tailnet |
| **Access Control** | None | Tailscale ACLs |

## Network Protocol

The video streaming protocol remains the same:

```
[Frame Size: 4 bytes, big-endian UInt32]
[Is Keyframe: 1 byte, 0 or 1]
[H.264 Frame Data: N bytes]
```

The difference is that this protocol now runs over Tailscale's encrypted tunnel instead of raw TCP.

## Troubleshooting

### "Initialization failed" error

- Ensure `libtailscale.a` is properly linked
- Check that the bridging header is configured correctly
- Verify build settings include the library and header paths

### "Start failed" error

- Check your auth key is valid and not expired
- Ensure you have network connectivity
- Look for error messages in console output
- Try using interactive login (no auth key) to diagnose

### Connection timeout

- Verify both nodes are connected to Tailscale (`tailscale status`)
- Check that the server is actually running and listening
- Confirm the hostname or IP address is correct
- Check Tailscale ACLs allow traffic on port 7447

### "Listener closed" error

- The server may have stopped or crashed
- Check server logs for errors
- Restart the server

## Performance Considerations

### Latency

- Tailscale adds minimal latency (typically <5ms)
- Direct peer-to-peer connections when possible
- DERP relay fallback when direct connection unavailable

### Throughput

- WireGuard encryption is very efficient
- Should handle 60 FPS H.264 streaming without issues
- Bandwidth usage same as raw TCP (only encryption overhead)

### CPU Usage

- WireGuard encryption is hardware-accelerated on modern CPUs
- Minimal impact on encoding/decoding performance

## Future Enhancements

Possible improvements to explore:

1. **Peer Discovery UI** - List available Cuple servers on your tailnet
2. **MagicDNS Integration** - Use Tailscale hostnames automatically
3. **ACL-based Authorization** - Check permissions before accepting connections
4. **Tailscale Funnel** - Share publicly via Tailscale Funnel (for presentations)
5. **Multi-user Support** - Multiple viewers per server with access control

## References

- [Tailscale tsnet Documentation](https://tailscale.com/kb/1244/tsnet)
- [libtailscale GitHub](https://github.com/tailscale/libtailscale)
- [Tailscale ACLs](https://tailscale.com/kb/1018/acls)
- [WireGuard Protocol](https://www.wireguard.com/)

## Status

⚠️ **Proof of Concept** - This integration is currently a proof of concept. Key items needed for production:

- [ ] Build and link actual libtailscale library
- [ ] Replace placeholder C function declarations with proper bridging header
- [ ] Add peer discovery functionality
- [ ] Add UI integration
- [ ] Test cross-network connectivity
- [ ] Add error recovery and reconnection logic
- [ ] Implement connection state management
- [ ] Add configuration persistence

## License

This integration follows the same license as Cuple. The libtailscale library is BSD 3-Clause.
