# Cuple - Secure Screen Sharing via Tailscale

[![Build Status](https://github.com/slaskis/cuple/actions/workflows/build.yml/badge.svg)](https://github.com/slaskis/cuple/actions/workflows/build.yml)

A minimal macOS menubar app for high-quality, low-latency screen sharing using Tailscale's encrypted peer-to-peer network. Built with Swift Package Manager (no Xcode required).

## Features

- **Menubar Integration**: Lightweight menubar app that stays out of your way
- **Tailscale Integration**: Secure, encrypted peer-to-peer connections via Tailscale
- **Automatic Peer Discovery**: Browse and connect to available shares on your tailnet with one click
- **Zero Configuration**: No port forwarding or firewall configuration needed
- **High Quality**: Hardware-accelerated H.264 encoding/decoding using VideoToolbox
- **Low Latency**: Optimized for real-time streaming with minimal delay
- **Retina Support**: Captures and streams at full Retina resolution
- **60 FPS**: Smooth 60 frames per second capture
- **Works Anywhere**: Share screens across networks, not just LAN

## Requirements

- macOS 15.0 (Sequoia) or later
- Swift 6.0 or later
- Screen Recording permission
- Tailscale account (free for personal use)

## Building

The project includes TailscaleKit as a local package with the libtailscale C library. Build using the provided Makefile:

```bash
make build
```

This will:
1. Build the libtailscale C library from the upstream submodule
2. Apply necessary patches
3. Build the Swift TailscaleKit wrapper
4. Build the Cuple application

For a release build:

```bash
make release
```

The executable will be at `.build/release/Cuple`

## Running

Run directly:

```bash
swift run
```

Or run the built executable:

```bash
.build/release/Cuple
```

## Testing on One Machine

You can test Cuple on a single machine without needing two computers:

### Quick Test (Easiest)

1. Build and run Cuple:
   ```bash
   make build
   .build/debug/Cuple
   ```

2. Click **"Start Sharing"** in the menubar

3. Click **"Browse Shares..."**

4. Your own machine will appear in the list - click **"Connect"**!

This creates both a server and client on the same machine, opening a window showing your own screen (creating a recursive mirror effect).

### Testing with Two Instances

To test like you have two separate machines:

**Terminal 1:**
```bash
CUPLE_INSTANCE=1 .build/debug/Cuple
# Click "Start Sharing" when Cuple opens
```

**Terminal 2:**
```bash
CUPLE_INSTANCE=2 .build/debug/Cuple
# Click "Browse Shares..." to find the first instance
```

`CUPLE_INSTANCE` suffixes the Tailscale state directory and hostname so the two processes register as distinct tailnet nodes. Without it, both instances share `~/Library/Application Support/Cuple/tailscale`, get the same machine key, and the browser sees zero peers because it's looking at its own node.

**Note:** This tests the full Tailscale integration and peer discovery, but doesn't test actual network traversal or NAT punch-through since both instances are on the same machine.

## CI/CD

The project includes GitHub Actions workflows for automated building and releases:

### Build Workflow
- Runs on every push to `main` and `claude/*` branches
- Builds on macOS 13 with the latest Swift toolchain
- Creates build artifacts for download
- Generates build reports to verify compilation

### Release Workflow
- Triggers on version tags (e.g., `v1.0.0`) or manual dispatch
- Builds optimized release binary
- Creates `.app` bundle with proper Info.plist
- Generates ZIP archive and checksums
- Publishes GitHub release with notes

To create a release:
```bash
git tag v1.0.0
git push origin v1.0.0
```

Or use the "Actions" tab to manually trigger a release build.

## Usage

### First Time Setup

1. Create a free Tailscale account at https://tailscale.com if you don't have one
2. Both the sharing and viewing computers need to be on the same Tailscale network (tailnet)

### Sharing Your Screen

1. Click the Cuple icon (📺) in the menubar
2. Select "Start Sharing"
3. Grant Screen Recording permission if prompted
4. Tailscale will automatically connect (ephemeral node, auto-cleanup)
5. Select "Show Tailscale Info" to see your Tailscale IP addresses
6. Share your hostname (e.g., "macbook-pro") or Tailscale IP with others

### Viewing a Shared Screen

**Option 1: Browse Shares (Easiest)**

1. Click the Cuple icon (📺) in the menubar
2. Select "Browse Shares..."
3. Available shares will be automatically discovered
4. Click "Connect" next to the share you want to view
5. A window will open showing the shared screen

**Option 2: Manual Connection**

1. Click the Cuple icon (📺) in the menubar
2. Select "Connect to..."
3. Enter the Tailscale hostname or IP address (e.g., "macbook-pro" or "100.x.x.x")
4. A window will open showing the shared screen

### Stopping

- To stop sharing: Select "Stop Sharing" from the menubar
- To stop viewing: Select "Disconnect" or close the viewer window
- Tailscale nodes are ephemeral and automatically cleaned up when you stop

## Architecture

### SwiftUI Interface
- Modern declarative UI using SwiftUI
- MenuBarExtra for native macOS menubar integration
- Observable state management with `@StateObject` and `@EnvironmentObject`
- Clean separation between UI and business logic

### Screen Capture
- Uses `ScreenCaptureKit` for efficient screen capture
- Captures at native Retina resolution (2x)
- 60 FPS capture rate with automatic frame pacing

### Video Encoding/Decoding
- Hardware-accelerated H.264 encoding via `VideoToolbox`
- Optimized for low latency with disabled frame reordering
- High-quality preset (~4 bits per pixel)
- Adaptive bitrate based on resolution

### Network Protocol
- Tailscale encrypted peer-to-peer connection on port 7447
- WireGuard-based encryption (via Tailscale)
- Simple framing protocol: `[size:4][keyframe:1][data:N]`
- No buffering for minimal latency
- Automatic keyframe requests every 2 seconds

### Tailscale Integration
- Uses official TailscaleKit framework (Swift wrapper for libtailscale)
- Ephemeral nodes (automatically cleaned up)
- Direct peer-to-peer connections via WireGuard
- No central relay server (unless DERP fallback needed)
- Works across networks, NATs, and firewalls

## Network Protocol Details

Each frame is transmitted as:
```
[Frame Size: 4 bytes, big-endian UInt32]
[Is Keyframe: 1 byte, 0 or 1]
[H.264 Frame Data: N bytes]
```

Port: `7447` (TCP)

## Privacy & Security

- **Encrypted**: All traffic encrypted via WireGuard (Tailscale)
- **Peer-to-Peer**: Direct connections between devices when possible
- **No Recording**: Frames are encoded and transmitted in real-time, not stored
- **Ephemeral Nodes**: Temporary Tailscale nodes that auto-cleanup
- **Screen Recording Permission**: macOS requires explicit user permission
- **Tailscale ACLs**: Control who can access your device via Tailscale admin console

## Performance Tips

- Tailscale will prefer direct peer-to-peer connections when possible
- Direct connections provide LAN-like performance even over the internet
- Use wired Ethernet for best quality and lowest latency
- Disable WiFi power saving for consistent performance
- Close bandwidth-intensive applications
- Check Tailscale status to ensure direct connection (not relayed)

## Troubleshooting

### "Permission Denied" when capturing screen
- Go to System Settings > Privacy & Security > Screen Recording
- Enable permission for Cuple or your Terminal app

### "Connection Failed"
- Verify both computers are on the same Tailscale network (tailnet)
- Check that Tailscale is running and connected on both machines
- Ensure the hostname or IP address is correct (use "Show Tailscale Info")
- Check Tailscale ACLs allow connections between devices

### Low FPS or stuttering
- Check network bandwidth (run `iperf3` between machines)
- Try reducing screen resolution temporarily
- Use wired Ethernet instead of WiFi

### Black screen or no video
- Restart both the sharing and viewing applications
- Verify Screen Recording permission is granted
- Check Console.app for error messages

## License

MIT License - Feel free to modify and distribute

## Technical Details

**Technologies:**
- Swift 6.0+
- SwiftUI (Modern declarative UI with MenuBarExtra)
- TailscaleKit (Official Swift wrapper for libtailscale)
- WireGuard (via Tailscale - encrypted networking)
- ScreenCaptureKit (Screen Capture)
- VideoToolbox (H.264 Encoding/Decoding)

**Quality Settings:**
- Resolution: Native Retina (2x scaling)
- Frame Rate: 60 FPS
- Codec: H.264 High Profile
- Bitrate: ~4 bits/pixel (adaptive)
- Keyframe Interval: 2 seconds
