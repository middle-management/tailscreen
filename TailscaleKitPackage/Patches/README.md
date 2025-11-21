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

**Status:** This should be submitted as a PR to upstream libtailscale.

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
