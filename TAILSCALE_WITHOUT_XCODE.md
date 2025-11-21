# Using Tailscale Without Xcode

Yes! You can use Tailscale with command-line Swift tools (SPM), though it requires some setup since TailscaleKit's build system currently uses Xcode.

## Three Approaches

### Option 1: Copy TailscaleKit Sources (Recommended)

The simplest approach is to copy the TailscaleKit Swift sources directly into your project:

```bash
# 1. Clone libtailscale
git clone https://github.com/tailscale/libtailscale.git /tmp/libtailscale

# 2. Build the C library (requires Go)
cd /tmp/libtailscale
make c-archive  # Creates libtailscale.a

# 3. Copy Swift sources into your project
mkdir -p TailscaleKit/LocalAPI
cp /tmp/libtailscale/swift/TailscaleKit/*.swift TailscaleKit/
cp /tmp/libtailscale/swift/TailscaleKit/LocalAPI/*.swift TailscaleKit/LocalAPI/

# 4. Copy the C library and header
mkdir -p lib
cp /tmp/libtailscale/libtailscale.a lib/
cp /tmp/libtailscale/tailscale.h include/

# 5. Create module map
mkdir -p Modules/libtailscale
cat > Modules/libtailscale/module.modulemap <<'EOF'
module libtailscale {
    header "../../include/tailscale.h"
    link "tailscale"
    export *
}
EOF
```

### Option 2: Use Swift Build with C Library

Update your `Package.swift` to link the C library:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Cuple",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "cuple", targets: ["Cuple"])
    ],
    targets: [
        .executableTarget(
            name: "Cuple",
            dependencies: ["TailscaleKit"],
            path: "Sources"
        ),

        // TailscaleKit as a local target
        .target(
            name: "TailscaleKit",
            dependencies: ["libtailscale"],
            path: "TailscaleKit",
            exclude: ["LocalAPI/GoTime.swift"]  // May need adjustment
        ),

        // C library wrapper
        .systemLibrary(
            name: "libtailscale",
            path: "Modules/libtailscale"
        ),
    ],
    linkerSettings: [
        .unsafeFlags([
            "-L", "./lib",
            "-ltailscale"
        ])
    ]
)
```

Then build with:

```bash
swift build -Xlinker -L./lib
```

### Option 3: Build Manually with swiftc

For maximum control, build directly with the Swift compiler:

```bash
# 1. Compile Swift sources
swiftc \
  -o cuple \
  -I include \
  -L lib \
  -ltailscale \
  -import-objc-header include/tailscale.h \
  Sources/*.swift \
  TailscaleKit/*.swift \
  TailscaleKit/LocalAPI/*.swift
```

## Complete Setup Guide (Option 1 - Recommended)

Here's a step-by-step guide to get everything working without Xcode:

### Step 1: Build libtailscale C Library

```bash
# Requirements: Go 1.21+
go version

# Clone and build
git clone https://github.com/tailscale/libtailscale.git
cd libtailscale

# Build for your architecture
make c-archive

# This creates:
# - libtailscale.a (static library)
# - tailscale.h (C header)
```

### Step 2: Copy Files to Your Project

```bash
# From the cuple project directory

# Create directories
mkdir -p TailscaleKit/LocalAPI
mkdir -p Modules/libtailscale
mkdir -p lib include

# Copy TailscaleKit Swift sources
cp /tmp/libtailscale/swift/TailscaleKit/*.swift TailscaleKit/
cp /tmp/libtailscale/swift/TailscaleKit/LocalAPI/*.swift TailscaleKit/LocalAPI/

# Copy C library and header
cp /tmp/libtailscale/libtailscale.a lib/
cp /tmp/libtailscale/tailscale.h include/
```

### Step 3: Create Module Map

```bash
cat > Modules/libtailscale/module.modulemap <<'EOF'
module libtailscale {
    header "../../include/tailscale.h"
    link "tailscale"
    export *
}
EOF
```

### Step 4: Update Package.swift

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Cuple",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "cuple", targets: ["Cuple"])
    ],
    targets: [
        .executableTarget(
            name: "Cuple",
            dependencies: ["TailscaleKit"],
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-L", "./lib"]),
                .linkedLibrary("tailscale")
            ]
        ),

        .target(
            name: "TailscaleKit",
            dependencies: ["libtailscale"],
            path: "TailscaleKit"
        ),

        .systemLibrary(
            name: "libtailscale",
            path: "Modules/libtailscale"
        ),
    ]
)
```

### Step 5: Build and Run

```bash
# Build
swift build

# Run
swift run cuple

# Or use the binary directly
.build/debug/cuple
```

## Project Structure

After setup, your project should look like:

```
cuple/
├── Package.swift
├── Sources/
│   ├── TailscaleScreenShareServer.swift
│   ├── TailscaleScreenShareClient.swift
│   └── ...
├── TailscaleKit/              ← TailscaleKit Swift sources
│   ├── TailscaleNode.swift
│   ├── Listener.swift
│   ├── OutgoingConnection.swift
│   ├── IncomingConnection.swift
│   ├── TailscaleError.swift
│   ├── LogSink.swift
│   ├── URLSession+Tailscale.swift
│   └── LocalAPI/
│       ├── LocalAPIClient.swift
│       ├── MessageProcessor.swift
│       ├── MessageReader.swift
│       ├── Types.swift
│       └── GoTime.swift
├── Modules/
│   └── libtailscale/
│       └── module.modulemap   ← Module map for C library
├── lib/
│   └── libtailscale.a         ← Compiled C library
└── include/
    └── tailscale.h            ← C header
```

## Building libtailscale Without Xcode

The C library can be built without Xcode, just needs Go:

```bash
cd libtailscale

# For macOS
make c-archive

# For Linux (if you want to explore cross-platform)
GOOS=linux GOARCH=amd64 make c-archive
```

Under the hood, this runs:

```bash
go build \
  -buildmode=c-archive \
  -o libtailscale.a \
  tailscale.go
```

## Advantages of Command-Line Approach

✅ **No Xcode required** - Just Swift CLI tools
✅ **CI/CD friendly** - Easy to automate
✅ **Lightweight** - Smaller dev environment
✅ **Cross-platform potential** - Could work on Linux with tweaks
✅ **Direct control** - Full visibility into build process

## Limitations

⚠️ **GUI apps** - SwiftUI apps typically need Xcode for app bundles
⚠️ **Code signing** - Manual signing required for distribution
⚠️ **Debugging** - lldb from command line (vs Xcode debugger)

## Alternative: Pre-built Framework

If you don't want to manage sources, you can still use the framework without Xcode:

```bash
# Build framework on a Mac with Xcode (one-time)
cd /tmp/libtailscale/swift
make macos

# Copy framework
cp -R build/Build/Products/Release/TailscaleKit.framework ~/Frameworks/

# Link in your project
swift build \
  -Xswiftc -F$HOME/Frameworks \
  -Xlinker -rpath -Xlinker $HOME/Frameworks
```

But this still requires Xcode for the initial build.

## Testing Without Xcode

```bash
# Run tests
swift test

# With specific test
swift test --filter TailscaleTests
```

## Running in Development

```bash
# Build and run server
swift run cuple --server

# Build and run client
swift run cuple --client <hostname>

# Or build once, run multiple times
swift build && .build/debug/cuple
```

## Distribution

For distributing without Xcode:

```bash
# Build release
swift build -c release

# Binary is at
.build/release/cuple

# Package with library
mkdir -p dist/lib
cp .build/release/cuple dist/
cp lib/libtailscale.a dist/lib/

# User runs:
./cuple
```

## Next Steps

1. Copy TailscaleKit sources into your project
2. Build libtailscale.a C library
3. Set up module map
4. Update Package.swift
5. `swift build` and you're done!

See the setup script below for automation.

## Automated Setup Script

```bash
#!/bin/bash
set -e

echo "Setting up TailscaleKit without Xcode..."

# Clone libtailscale
if [ ! -d "/tmp/libtailscale" ]; then
    git clone https://github.com/tailscale/libtailscale.git /tmp/libtailscale
fi

cd /tmp/libtailscale
make c-archive

# Return to project
cd -

# Create directories
mkdir -p TailscaleKit/LocalAPI Modules/libtailscale lib include

# Copy files
cp /tmp/libtailscale/swift/TailscaleKit/*.swift TailscaleKit/
cp /tmp/libtailscale/swift/TailscaleKit/LocalAPI/*.swift TailscaleKit/LocalAPI/
cp /tmp/libtailscale/libtailscale.a lib/
cp /tmp/libtailscale/tailscale.h include/

# Create module map
cat > Modules/libtailscale/module.modulemap <<'EOF'
module libtailscale {
    header "../../include/tailscale.h"
    link "tailscale"
    export *
}
EOF

echo "✅ Setup complete! Now run: swift build"
```

Save this as `setup-tailscale.sh`, make it executable, and run it:

```bash
chmod +x setup-tailscale.sh
./setup-tailscale.sh
swift build
```

That's it! You can now use Tailscale completely without Xcode.
