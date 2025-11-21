# Using TailscaleKit Package

Quick guide on how to set up and use the TailscaleKit package in your Swift projects.

## Initial Setup

### 1. Clone or Initialize the Package

If starting fresh:

```bash
cd TailscaleKitPackage
git init
git submodule add https://github.com/tailscale/libtailscale.git upstream/libtailscale
```

If cloning an existing repo:

```bash
git clone --recurse-submodules <repo-url>
```

Or after cloning:

```bash
git submodule update --init --recursive
```

### 2. Run Setup Script

```bash
cd TailscaleKitPackage
./setup.sh
```

This will:
- Initialize the libtailscale submodule
- Build `libtailscale.a` (requires Go)
- Copy TailscaleKit Swift sources
- Set up the module map

### 3. Verify the Build

```bash
swift build
```

## Using in Your Project

### Option 1: Local Package Dependency (Development)

In your `Package.swift`:

```swift
dependencies: [
    .package(path: "../TailscaleKitPackage")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "TailscaleKit", package: "TailscaleKitPackage")
        ]
    )
]
```

### Option 2: Git Dependency (Production)

Host the TailscaleKitPackage as a separate git repository, then:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/TailscaleKitPackage", branch: "main")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: ["TailscaleKit"]
    )
]
```

## Code Example

```swift
import TailscaleKit

// Define a logger
struct AppLogger: LogSink {
    var logFileHandle: Int32? = nil

    func log(_ message: String) {
        print("[Tailscale] \(message)")
    }
}

// Configure Tailscale
let config = Configuration(
    hostName: "my-swift-app",
    path: "/tmp/tailscale",
    authKey: ProcessInfo.processInfo.environment["TS_AUTHKEY"],
    controlURL: kDefaultControlURL,
    ephemeral: true
)

// Create and start node
let node = try TailscaleNode(config: config, logger: AppLogger())
try await node.up()

// Get IP addresses
let ips = try await node.addrs()
print("Connected! IPv4: \(ips.ip4 ?? "none")")

// Listen for connections
let listener = try await Listener(
    tailscale: node.tailscale!,
    proto: .tcp,
    address: ":7447",
    logger: AppLogger()
)

print("Listening on :7447...")

// Accept a connection
let incoming = try await listener.accept(timeout: 60.0)
print("Connection from: \(incoming.remoteAddress ?? "unknown")")

// Receive data
let data = try await incoming.receive(maximumLength: 4096, timeout: 10_000)
print("Received \(data.count) bytes")
```

## Project Structure After Setup

Your project should look like:

```
YourProject/
├── Package.swift                    # Depends on TailscaleKitPackage
├── Sources/
│   └── YourApp/
│       └── main.swift              # Uses TailscaleKit
└── TailscaleKitPackage/            # Local package
    ├── Package.swift
    ├── setup.sh
    ├── Sources/
    │   └── TailscaleKit/           # Swift sources (after setup)
    ├── lib/
    │   └── libtailscale.a          # C library (after setup)
    ├── include/
    │   └── tailscale.h
    └── upstream/
        └── libtailscale/           # Git submodule
```

## Building Your Project

```bash
# Build
swift build

# Run
swift run

# Test
swift test

# Release build
swift build -c release
```

## Updating TailscaleKit

When Tailscale releases updates:

```bash
cd TailscaleKitPackage
./setup.sh --update
```

Or manually:

```bash
cd TailscaleKitPackage/upstream/libtailscale
git pull origin main
cd ../..
./setup.sh
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Build

on: [push, pull_request]

jobs:
  build:
    runs-on: macos-latest

    steps:
      - uses: actions/checkout@v3
        with:
          submodules: recursive

      - uses: actions/setup-go@v4
        with:
          go-version: '1.21'

      - name: Setup TailscaleKit
        run: |
          cd TailscaleKitPackage
          ./setup.sh

      - name: Build
        run: swift build

      - name: Test
        run: swift test
```

## Troubleshooting

### Module not found

```bash
cd TailscaleKitPackage
./setup.sh
```

### Go not installed

Install Go from https://go.dev/dl/

### Submodule not initialized

```bash
git submodule update --init --recursive
```

### Build fails

1. Clean build:
   ```bash
   swift package clean
   rm -rf .build
   ```

2. Re-run setup:
   ```bash
   cd TailscaleKitPackage
   ./setup.sh
   ```

3. Try building again:
   ```bash
   swift build
   ```

## Platform-Specific Builds

### macOS

Default setup works for macOS:

```bash
./setup.sh
swift build
```

### iOS

For iOS, build the appropriate C library:

```bash
cd upstream/libtailscale

# For iOS device
make c-archive-ios

# For iOS simulator
make c-archive-ios-sim
```

Then use the appropriate library in your project.

## Environment Variables

### TS_AUTHKEY

Set your Tailscale auth key as an environment variable:

```bash
export TS_AUTHKEY="tskey-auth-..."
swift run
```

Or pass it in code:

```swift
let config = Configuration(
    hostName: "my-app",
    path: "/tmp/tailscale",
    authKey: "tskey-auth-...",  // Direct
    controlURL: kDefaultControlURL,
    ephemeral: true
)
```

Get auth keys from: https://login.tailscale.com/admin/settings/keys

## Next Steps

1. ✅ Set up TailscaleKit package
2. ✅ Add to your project's Package.swift
3. ✅ Get Tailscale auth key
4. ✅ Import and use TailscaleKit
5. 🚀 Build your networked app!

See README.md for full API documentation.
