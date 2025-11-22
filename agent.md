# Agent Guide for Cuple

This document provides guidance for AI agents working on the Cuple screen sharing application.

## Project Overview

**Cuple** is a macOS menubar application for secure peer-to-peer screen sharing over Tailscale. It uses Tailscale's tsnet (ephemeral nodes) for encrypted, zero-configuration networking.

**Tech Stack:**
- Swift 6.0 with strict concurrency checking
- SwiftUI for UI
- TailscaleKit (official Swift framework)
- macOS 15.0+
- Go (for building libtailscale)

## Architecture

### Core Components

1. **TailscaleScreenShareServer** (`Sources/TailscaleScreenShareServer.swift`)
   - Manages Tailscale ephemeral node as server
   - Captures and streams screen content
   - Exposes `node` property for peer discovery access

2. **TailscaleScreenShareClient** (`Sources/TailscaleScreenShareClient.swift`)
   - Connects to remote shares via Tailscale
   - Receives and displays remote screen
   - Exposes `node` property for peer discovery access

3. **AppState** (`Sources/AppState.swift`)
   - Central state management (`@MainActor` class)
   - Coordinates server, client, and authentication
   - Published properties for UI binding

4. **TailscalePeerDiscovery** (`Sources/TailscalePeerDiscovery.swift`)
   - Discovers other Cuple instances on tailnet
   - Uses LocalAPI to query peer status
   - Parallel TCP port checking with timeouts

5. **TailscaleAuth** (`Sources/TailscaleAuth.swift`)
   - Manages Tailscale authentication state
   - Interactive login flow (browser-based)
   - Profile display and sign-out

6. **MenuBarView** (`Sources/MenuBarView.swift`)
   - SwiftUI menubar interface
   - Native macOS styling and interactions
   - Multiple sheet views for different workflows

### Package Structure

```
cuple/
├── Sources/                    # Swift source files
├── TailscaleKitPackage/       # Git submodule
│   ├── upstream/              # TailscaleKit submodule
│   ├── lib/                   # Symlink to built library
│   └── Package.swift          # TailscaleKit package config
├── Package.swift              # Main package config
└── Makefile                   # Build system
```

## Swift 6 Concurrency

This project uses **strict concurrency checking**. Key patterns:

### Main Actor Isolation
```swift
@MainActor
class AppState: ObservableObject {
    // All UI-related state must be on MainActor
}
```

### Sendable Conformance
```swift
// For classes that cross concurrency boundaries
class ScreenShareClient: @unchecked Sendable {
    // Manual thread safety assertion
}

// For data types
struct CuplePeer: Identifiable, Sendable {
    // All stored properties must be Sendable
}
```

### Async/Await Patterns
```swift
// Await async properties
guard let tailscaleHandle = await node.tailscale else { ... }

// Propagate async through call chain
func startSharing() async { ... }
```

### Common Pitfalls
1. **CVPixelBuffer is NOT Sendable** - Convert to CGImage before MainActor jump
2. **Task in deinit** - Don't capture self, use synchronous cleanup
3. **Missing await** - All async calls must be awaited
4. **MainActor isolation** - Window/UI creation must be @MainActor

## Build System

### Building

```bash
# Full build (includes Go library compilation)
make build

# Clean build
make clean build

# Run application
make run
```

### Dependencies

The build requires:
- Swift 6.0+
- Go 1.21+ (for libtailscale)
- Network access for Go module downloads

**Important:** The `libtailscale.a` library must be built first. If network is unavailable, the build will fail during Go dependency download.

### Linker Configuration

Library path is configured in `Package.swift`:
```swift
linkerSettings: [
    .unsafeFlags(["-L", "TailscaleKitPackage/lib"])
]
```

Use **relative paths** only - absolute paths break portability.

## UI Design Patterns

### Native macOS Styling

The UI follows macOS Human Interface Guidelines:

```swift
// System fonts with explicit sizes
.font(.system(size: 13, weight: .medium))

// System colors for theme support
.foregroundStyle(.secondary)
Color(nsColor: .controlBackgroundColor)

// Consistent spacing
.padding(.horizontal, 10)
.padding(.vertical, 5)

// Hover states
.onHover { hovering in
    isHovered = hovering
}

// Proper control sizes
.controlSize(.large)
```

### Menu Structure

The menubar is 220px wide with sections:
1. Sharing controls (Start/Stop)
2. Connection controls (Browse/Connect/Disconnect)
3. Info display
4. Authentication (login/profile/signout)
5. Status indicators
6. Quit

## Common Tasks

### Adding a New Feature

1. Update `AppState` with necessary state
2. Add UI in `MenuBarView` or create new sheet
3. Ensure proper async/await propagation
4. Test with Swift 6 concurrency checking
5. Follow native macOS design patterns

### Working with Tailscale LocalAPI

```swift
let client = LocalAPIClient(localNode: node, logger: logger)
let status = try await client.backendStatus()

// Access peer information
for (peerKey, peerStatus) in status.Peer ?? [:] {
    // Process peers
}
```

### Testing Locally

Use `test-local.sh` to run two instances:
```bash
./test-local.sh
# Then manually run second instance in another terminal
```

## Important Patterns

### Error Handling

```swift
do {
    try await someAsyncOperation()
} catch {
    showAlertMessage(
        title: "Operation Failed",
        message: error.localizedDescription
    )
}
```

### Task Management in UI

```swift
MenuButton("Action", systemImage: "icon.name") {
    Task {
        await appState.performAction()
    }
}
```

### Sheet Presentation

```swift
// In AppState
@Published var showMySheet = false

// In MenuBarView
.sheet(isPresented: $appState.showMySheet) {
    MySheet()
        .environmentObject(appState)
}
```

## Known Issues & Gotchas

1. **Build requires network** - Go needs to download dependencies for libtailscale
2. **Ephemeral nodes** - Tailscale nodes are temporary and auto-cleanup
3. **Port 7447** - Hardcoded in multiple places (TailscalePeerDiscovery, servers)
4. **Auth requires active node** - Must start sharing or connect before login
5. **ScreenCapture permissions** - macOS requires screen recording permission

## Git Workflow

Current branch: `claude/tailscale-tsnet-exploration-01AeQUK8Y9cycVbFwuCqfaaa`

### Commit Guidelines

- Use descriptive commit messages
- Include "why" not just "what"
- Multi-line messages for complex changes
- Reference file locations in descriptions

### Pushing

```bash
git push -u origin claude/tailscale-tsnet-exploration-01AeQUK8Y9cycVbFwuCqfaaa
```

## File Locations Reference

| Component | File | Purpose |
|-----------|------|---------|
| Main entry | `Sources/main.swift` | App initialization |
| State management | `Sources/AppState.swift` | Central state |
| UI | `Sources/MenuBarView.swift` | All SwiftUI views |
| Server | `Sources/TailscaleScreenShareServer.swift` | Sharing functionality |
| Client | `Sources/TailscaleScreenShareClient.swift` | Viewing functionality |
| Discovery | `Sources/TailscalePeerDiscovery.swift` | Peer finding |
| Auth | `Sources/TailscaleAuth.swift` | Authentication |
| Screen capture | `Sources/ScreenCapture.swift` | macOS screen recording |

## Testing Strategy

1. **Local testing** - Two instances on one machine
2. **Tailnet testing** - Multiple machines on same tailnet
3. **Auth flow** - Login, display profile, signout
4. **Discovery** - Find and connect to peers
5. **Screen sharing** - Full capture and display pipeline

## Future Considerations

- Persist authentication state
- Custom port configuration
- Performance optimization for high-resolution displays
- ACL integration for access control
- MagicDNS hostname resolution

## Getting Help

- Tailscale docs: https://tailscale.com/kb/
- TailscaleKit: https://github.com/tailscale/tailscale-ios
- Swift concurrency: https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html
- macOS HIG: https://developer.apple.com/design/human-interface-guidelines/macos

---

**Last Updated:** 2025-11-22
**Swift Version:** 6.0
**macOS Target:** 15.0+
**TailscaleKit:** Latest from submodule
