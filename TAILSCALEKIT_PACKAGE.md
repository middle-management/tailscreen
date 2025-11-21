# TailscaleKit Package Setup

The `TailscaleKitPackage/` directory contains a standalone Swift Package that wraps the official TailscaleKit framework from Tailscale's libtailscale repository.

## Why a Separate Package?

Having TailscaleKit as a separate package provides:

✅ **Clean separation** - TailscaleKit is independent from Cuple
✅ **Reusability** - Can be used by other projects
✅ **Easy updates** - Update Tailscale independently
✅ **Proper SPM structure** - Standard Swift Package Manager layout
✅ **Git submodule** - Tracks upstream libtailscale directly

## Directory Structure

```
cuple/
├── Package.swift                    # Depends on ./TailscaleKitPackage
├── Sources/                         # Cuple source code
│   ├── TailscaleScreenShareServer.swift
│   └── TailscaleScreenShareClient.swift
└── TailscaleKitPackage/             # Separate Swift Package (not tracked)
    ├── Package.swift
    ├── setup.sh
    ├── README.md
    ├── upstream/
    │   └── libtailscale/           # Git submodule
    ├── Sources/
    │   └── TailscaleKit/           # Swift sources (after setup)
    ├── lib/
    │   └── libtailscale.a          # C library (after setup)
    └── include/
        └── tailscale.h
```

## Initial Setup

The TailscaleKitPackage directory is **not tracked by git** (it's in `.gitignore`) because it's its own git repository with a submodule.

### First Time Setup

```bash
cd TailscaleKitPackage

# Initialize git and add submodule
git init
git submodule add https://github.com/tailscale/libtailscale.git upstream/libtailscale
git add .
git commit -m "Initial TailscaleKit package"

# Run setup to build C library and copy Swift sources
./setup.sh
```

### After Cloning Cuple

If you're cloning the Cuple repository, you need to set up TailscaleKit separately:

```bash
# Clone Cuple
git clone <cuple-repo-url>
cd cuple

# The TailscaleKitPackage directory already exists with setup files
cd TailscaleKitPackage

# Initialize git and submodule
git init
git submodule add https://github.com/tailscale/libtailscale.git upstream/libtailscale

# Run setup
./setup.sh
```

## Building Cuple with TailscaleKit

Once TailscaleKit is set up:

```bash
cd cuple
swift build
```

The main `Package.swift` references TailscaleKit as a local dependency:

```swift
dependencies: [
    .package(path: "./TailscaleKitPackage")
]
```

## Updating TailscaleKit

To update to the latest version of TailscaleKit:

```bash
cd TailscaleKitPackage
./setup.sh --update
```

This will:
1. Update the libtailscale submodule to latest
2. Rebuild the C library
3. Copy updated Swift sources

## Alternative: Host TailscaleKit Separately

For production use, you might want to host TailscaleKit as its own repository:

1. **Create a new repo** for TailscaleKit:
   ```bash
   cd TailscaleKitPackage
   git remote add origin <your-tailscalekit-repo-url>
   git push -u origin main
   ```

2. **Update Cuple's Package.swift** to use the remote:
   ```swift
   dependencies: [
       .package(url: "<your-tailscalekit-repo-url>", branch: "main")
   ]
   ```

3. **Remove the local directory**:
   ```bash
   cd ..
   rm -rf TailscaleKitPackage
   ```

Then Swift Package Manager will fetch TailscaleKit remotely.

## Why Not a Git Submodule?

TailscaleKitPackage itself **contains** a git submodule (upstream/libtailscale), so making it a submodule of Cuple would create nested submodules, which is more complex than needed.

Instead:
- **Development**: Use local path dependency (current setup)
- **Production**: Host TailscaleKit separately and use git URL dependency

## Quick Reference

### Setup Commands

```bash
# First time
cd TailscaleKitPackage
git init
git submodule add https://github.com/tailscale/libtailscale.git upstream/libtailscale
./setup.sh

# Update
./setup.sh --update

# Build Cuple
cd ..
swift build
```

### File Locations

- **TailscaleKit package**: `./TailscaleKitPackage/`
- **Upstream source**: `./TailscaleKitPackage/upstream/libtailscale/`
- **Built library**: `./TailscaleKitPackage/lib/libtailscale.a`
- **Swift sources**: `./TailscaleKitPackage/Sources/TailscaleKit/`

## Documentation

See the following files in `TailscaleKitPackage/`:

- **README.md** - Complete package documentation
- **USAGE.md** - Usage examples and integration guide
- **setup.sh** - Automated setup script

## Troubleshooting

### "No such module 'TailscaleKit'"

Run the setup:

```bash
cd TailscaleKitPackage
./setup.sh
```

### "Cannot resolve package"

Make sure TailscaleKitPackage exists and has been set up:

```bash
ls TailscaleKitPackage/Package.swift  # Should exist
cd TailscaleKitPackage
./setup.sh
```

### Submodule issues

```bash
cd TailscaleKitPackage
git submodule update --init --recursive
./setup.sh
```

## Architecture

```
┌─────────────────────────────────────┐
│           Cuple App                 │
│   (TailscaleScreenShareServer/      │
│    TailscaleScreenShareClient)      │
└──────────────┬──────────────────────┘
               │ imports TailscaleKit
               ▼
┌─────────────────────────────────────┐
│      TailscaleKit Package           │
│   (Separate Swift Package)          │
│                                     │
│   Sources/TailscaleKit/             │
│   ├─ TailscaleNode.swift            │
│   ├─ Listener.swift                 │
│   ├─ OutgoingConnection.swift       │
│   └─ ...                            │
└──────────────┬──────────────────────┘
               │ wraps
               ▼
┌─────────────────────────────────────┐
│         libtailscale                │
│   (Git submodule)                   │
│                                     │
│   upstream/libtailscale/            │
│   ├─ libtailscale.a (C library)     │
│   └─ swift/TailscaleKit/ (sources)  │
└─────────────────────────────────────┘
```

The architecture keeps concerns separated:
- **Cuple** - Your screen sharing app
- **TailscaleKit Package** - Reusable Tailscale integration
- **libtailscale** - Upstream Tailscale C library

This makes updates easy and keeps the codebase clean!
