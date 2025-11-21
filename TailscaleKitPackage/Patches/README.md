# Patches for Upstream TailscaleKit

This directory contains patches that fix bugs or add necessary changes to the upstream TailscaleKit Swift sources.

## How it Works

- **Patches are automatically applied** before building via the Makefile
- The `.patches-applied` marker file tracks whether patches have been applied
- Patches are applied to `upstream/libtailscale/swift/TailscaleKit/` (which is symlinked to `Sources/TailscaleKit`)

## Managing Patches

### Apply patches manually:
```bash
make apply-patches
```

### Revert patches:
```bash
make unapply-patches
```

### Clean build (also reverts patches):
```bash
make clean
```

## Current Patches

### 001-add-foundation-import.patch
**Issue:** Upstream's `URLSession+Tailscale.swift` is missing `import Foundation`, causing compilation errors.

**Fix:** Adds `import Foundation` to make `URLSessionConfiguration` available.

**Status:** Should be submitted as a PR to upstream libtailscale.

### 002-add-libtailscale-import-tailscalenode.patch
**Issue:** `TailscaleNode.swift` doesn't import the `libtailscale` C module, causing "cannot find 'tailscale_*'" errors.

**Fix:** Adds `import libtailscale` to make C functions visible to Swift.

**Status:** Required for Swift Package Manager builds; upstream uses Xcode which may handle this differently.

### 003-add-libtailscale-import-listener.patch
**Issue:** `Listener.swift` doesn't import the `libtailscale` C module.

**Fix:** Adds `import libtailscale`.

**Status:** Required for Swift Package Manager builds.

### 004-add-libtailscale-import-outgoingconnection.patch
**Issue:** `OutgoingConnection.swift` doesn't import the `libtailscale` C module.

**Fix:** Adds `import libtailscale`.

**Status:** Required for Swift Package Manager builds.

### 005-add-libtailscale-import-tailscaleerror.patch
**Issue:** `TailscaleError.swift` doesn't import the `libtailscale` C module.

**Fix:** Adds `import libtailscale`.

**Status:** Required for Swift Package Manager builds.

## Creating New Patches

1. Make your changes to files in `upstream/libtailscale/swift/TailscaleKit/`
2. Generate a patch:
   ```bash
   git -C upstream/libtailscale diff swift/TailscaleKit/YourFile.swift > Patches/002-description.patch
   ```
3. Edit the patch to use the correct path (should start with `a/upstream/libtailscale/`)
4. Test the patch:
   ```bash
   make unapply-patches
   make apply-patches
   ```
