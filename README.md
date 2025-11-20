# Cuple - High-Quality Screen Sharing over LAN

A minimal macOS menubar app for high-quality, low-latency screen sharing over local network. Built with Swift Package Manager (no Xcode required).

## Features

- **Menubar Integration**: Lightweight menubar app that stays out of your way
- **High Quality**: Hardware-accelerated H.264 encoding/decoding using VideoToolbox
- **Low Latency**: Optimized for real-time streaming with minimal delay
- **LAN Only**: Direct peer-to-peer connection over local network
- **Retina Support**: Captures and streams at full Retina resolution
- **60 FPS**: Smooth 60 frames per second capture

## Requirements

- macOS 13.0 (Ventura) or later
- Swift 5.9 or later
- Screen Recording permission

## Building

Build the app using Swift Package Manager:

```bash
swift build -c release
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

## Usage

### Sharing Your Screen

1. Click the Cuple icon (📺) in the menubar
2. Select "Start Sharing"
3. Grant Screen Recording permission if prompted
4. Select "Show IP Address" to see your local IP addresses
5. Share your IP address with others who want to view your screen

### Viewing a Shared Screen

1. Click the Cuple icon (📺) in the menubar
2. Select "Connect to..."
3. Enter the IP address of the computer sharing their screen
4. A window will open showing the shared screen

### Stopping

- To stop sharing: Select "Stop Sharing" from the menubar
- To stop viewing: Select "Disconnect" or close the viewer window

## Architecture

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
- Direct TCP connection on port 7447
- Simple framing protocol: `[size:4][keyframe:1][data:N]`
- No buffering for minimal latency
- Automatic keyframe requests every 2 seconds

## Network Protocol Details

Each frame is transmitted as:
```
[Frame Size: 4 bytes, big-endian UInt32]
[Is Keyframe: 1 byte, 0 or 1]
[H.264 Frame Data: N bytes]
```

Port: `7447` (TCP)

## Privacy & Security

- **LAN Only**: No internet connectivity, all traffic stays on local network
- **No Recording**: Frames are encoded and transmitted in real-time, not stored
- **Direct Connection**: Peer-to-peer, no intermediary servers
- **Screen Recording Permission**: macOS requires explicit user permission

## Performance Tips

- Use wired Ethernet for best quality and lowest latency
- Ensure both computers are on the same local network
- Disable WiFi power saving for consistent performance
- Close bandwidth-intensive applications

## Troubleshooting

### "Permission Denied" when capturing screen
- Go to System Settings > Privacy & Security > Screen Recording
- Enable permission for Cuple or your Terminal app

### "Connection Failed"
- Verify both computers are on the same network
- Check firewall settings allow incoming connections on port 7447
- Ensure the IP address is correct (use "Show IP Address")

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
- Swift 5.9+
- ScreenCaptureKit (Screen Capture)
- VideoToolbox (H.264 Encoding/Decoding)
- Network Framework (TCP Communication)
- AppKit (Menubar UI)

**Quality Settings:**
- Resolution: Native Retina (2x scaling)
- Frame Rate: 60 FPS
- Codec: H.264 High Profile
- Bitrate: ~4 bits/pixel (adaptive)
- Keyframe Interval: 2 seconds
