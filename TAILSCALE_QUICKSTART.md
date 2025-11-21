# Tailscale Integration - Quick Start Guide

A minimal guide to get started with Tailscale networking in Cuple.

## TL;DR

```bash
# 1. Get an auth key from Tailscale
open https://login.tailscale.com/admin/settings/keys

# 2. Set it as environment variable
export TS_AUTHKEY="tskey-auth-xxxxxxxxxxxxx"

# 3. Build and link libtailscale (see TAILSCALE_INTEGRATION.md for details)
cd /path/to/libtailscale
make archive

# 4. Use the Tailscale classes in your app
```

## Code Examples

### Server Example

```swift
import Foundation

// Create and start a Tailscale server
let server = TailscaleScreenShareServer()

Task {
    do {
        // Start server (uses TS_AUTHKEY from environment)
        try await server.start(hostname: "my-mac")

        // Print Tailscale IPs
        let ips = server.getIPAddresses()
        print("✅ Server running on: \(ips.joined(separator: ", "))")
        print("📱 Others can connect using: my-mac")

        // Server will automatically:
        // - Capture screen
        // - Encode to H.264
        // - Stream to connected clients

    } catch {
        print("❌ Server failed: \(error)")
    }
}

// Stop when done
server.stop()
```

### Client Example

```swift
import Foundation

// Create and connect a Tailscale client
let client = TailscaleScreenShareClient()

Task {
    do {
        // Connect to server by hostname
        try await client.connect(to: "my-mac", port: 7447)

        print("✅ Connected! Video window will appear automatically.")

        // Client will automatically:
        // - Receive H.264 stream
        // - Decode frames
        // - Display in window

    } catch {
        print("❌ Connection failed: \(error)")
    }
}

// Disconnect when done
client.disconnect()
```

## Integration with Existing AppState

To add Tailscale as an option alongside the existing TCP networking:

```swift
// Add to AppState.swift
@Observable
class AppState {
    var useTailscale: Bool = false  // Toggle between TCP and Tailscale

    // Existing
    var screenShareServer: ScreenShareServer?
    var screenShareClient: ScreenShareClient?

    // New Tailscale
    var tailscaleServer: TailscaleScreenShareServer?
    var tailscaleClient: TailscaleScreenShareClient?

    func startSharing() {
        if useTailscale {
            // Use Tailscale
            let server = TailscaleScreenShareServer()
            tailscaleServer = server

            Task {
                try? await server.start(hostname: Host.current().localizedName ?? "cuple")
                let ips = server.getIPAddresses()
                print("Share via Tailscale: \(ips.first ?? "unknown")")
            }
        } else {
            // Use traditional TCP
            let server = ScreenShareServer(port: 7447)
            screenShareServer = server
            try? server.start()
        }
    }

    func connectToServer(address: String) {
        if useTailscale {
            // Use Tailscale
            let client = TailscaleScreenShareClient()
            tailscaleClient = client

            Task {
                try? await client.connect(to: address, port: 7447)
            }
        } else {
            // Use traditional TCP
            let client = ScreenShareClient()
            screenShareClient = client

            Task {
                try? await client.connect(to: address, port: 7447)
            }
        }
    }
}
```

## Simple UI Toggle

Add a toggle in your menu bar to switch modes:

```swift
// In MenuBarView.swift
Toggle("Use Tailscale", isOn: $appState.useTailscale)
```

## Required Steps Before Running

⚠️ **Important**: The code won't compile yet! You need to:

### 1. Build libtailscale

```bash
git clone https://github.com/tailscale/libtailscale.git
cd libtailscale
make archive
# Creates: libtailscale.a and tailscale.h
```

### 2. Add to Xcode Project

1. Create directories in your project:
   ```bash
   mkdir -p lib include
   cp /path/to/libtailscale/libtailscale.a lib/
   cp /path/to/libtailscale/tailscale.h include/
   ```

2. In Xcode:
   - **Build Phases** → **Link Binary With Libraries** → Add `lib/libtailscale.a`
   - **Build Settings** → **Header Search Paths** → Add `$(PROJECT_DIR)/include`
   - **Build Settings** → **Library Search Paths** → Add `$(PROJECT_DIR)/lib`

### 3. Create Bridging Header

Create `Cuple-Bridging-Header.h`:

```c
#ifndef Cuple_Bridging_Header_h
#define Cuple_Bridging_Header_h

#import "tailscale.h"

#endif
```

In Xcode:
- **Build Settings** → **Objective-C Bridging Header** → Set to `Cuple-Bridging-Header.h`

### 4. Remove Placeholder Declarations

In `TailscaleNetwork.swift`, remove the placeholder `@_silgen_name` declarations (lines 11-50) since they'll now come from the bridging header.

### 5. Get an Auth Key

```bash
# Visit: https://login.tailscale.com/admin/settings/keys
# Create a new auth key with "Ephemeral" checked
# Copy the key and export it:
export TS_AUTHKEY="tskey-auth-xxxxxxxxxxxxx"
```

## Testing the Integration

### Test 1: Server Start

```swift
let server = TailscaleScreenShareServer()
try await server.start()
print(server.getIPAddresses())
```

**Expected output:**
```
🔷 Starting Tailscale network...
✅ Tailscale connected! IP addresses: 100.64.0.1
🔷 Starting listener on port 7447...
✅ Listening on Tailscale port 7447
🔷 Starting screen capture...
✅ Screen share server started!
```

### Test 2: Client Connect

```swift
let client = TailscaleScreenShareClient()
try await client.connect(to: "100.64.0.1")
```

**Expected output:**
```
🔷 Starting Tailscale client...
🔷 Connecting to Tailscale network...
✅ Tailscale connected! IP addresses: 100.64.0.2
🔷 Connecting to 100.64.0.1:7447...
✅ Connected to 100.64.0.1!
```

## Debugging

### Check Tailscale Status

While your app is running, in a terminal:

```bash
# Install Tailscale CLI if not already installed
brew install tailscale

# Check network status
tailscale status

# Should show your app's nodes:
# 100.64.0.1    my-mac               ...
# 100.64.0.2    cuple-client-abc123  ...
```

### Common Issues

**"Initialization failed"**
- Library not linked correctly
- Check Xcode build settings

**"Start failed: invalid auth key"**
- Auth key expired or invalid
- Generate a new one from Tailscale admin

**"Connection refused"**
- Server not running
- Firewall blocking (unlikely with Tailscale)
- Wrong hostname/IP

## Next Steps

1. ✅ Complete the setup steps above
2. ✅ Test with server and client
3. ✅ Add UI controls for Tailscale mode
4. 🔜 Implement peer discovery (list available servers)
5. 🔜 Add connection state indicators
6. 🔜 Add error handling UI

## Questions?

See the full documentation: [TAILSCALE_INTEGRATION.md](./TAILSCALE_INTEGRATION.md)
