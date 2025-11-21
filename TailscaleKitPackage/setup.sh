#!/bin/bash
# Build script for TailscaleKit Swift Package
# This script only builds the C library - Swift sources are symlinked

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔷 Building libtailscale C library..."
echo

# Check for Go
if ! command -v go &> /dev/null; then
    echo "❌ Go is required to build libtailscale"
    echo "   Install from: https://go.dev/dl/"
    exit 1
fi

echo "✅ Go found: $(go version)"
echo

# Check submodule
if [ ! -e "upstream/libtailscale/.git" ]; then
    echo "❌ Submodule not initialized"
    echo "   Run: git submodule update --init --recursive"
    exit 1
fi

# Check if submodule has content
if [ ! -f "upstream/libtailscale/Makefile" ]; then
    echo "❌ Submodule is empty"
    echo "   Run: git submodule update --init --recursive"
    exit 1
fi

echo "✅ Submodule initialized"
echo

# Build C library
echo "🔨 Building libtailscale.a..."
cd upstream/libtailscale
make c-archive

if [ ! -f "libtailscale.a" ]; then
    echo "❌ Failed to build libtailscale.a"
    exit 1
fi

echo "✅ libtailscale.a built successfully"
echo

cd "$SCRIPT_DIR"

# Verify symlinks
echo "🔍 Verifying setup..."
echo

ERRORS=0

if [ ! -L "lib/libtailscale.a" ]; then
    echo "❌ lib/libtailscale.a symlink missing"
    ERRORS=$((ERRORS + 1))
elif [ ! -e "lib/libtailscale.a" ]; then
    echo "❌ lib/libtailscale.a symlink broken (library not built)"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ lib/libtailscale.a"
fi

if [ ! -L "include/tailscale.h" ]; then
    echo "❌ include/tailscale.h symlink missing"
    ERRORS=$((ERRORS + 1))
elif [ ! -e "include/tailscale.h" ]; then
    echo "❌ include/tailscale.h symlink broken"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ include/tailscale.h"
fi

if [ ! -L "Sources/TailscaleKit" ]; then
    echo "❌ Sources/TailscaleKit symlink missing"
    ERRORS=$((ERRORS + 1))
elif [ ! -e "Sources/TailscaleKit" ]; then
    echo "❌ Sources/TailscaleKit symlink broken"
    ERRORS=$((ERRORS + 1))
else
    SWIFT_FILE_COUNT=$(find -L Sources/TailscaleKit -name "*.swift" 2>/dev/null | wc -l | xargs)
    echo "✅ Sources/TailscaleKit ($SWIFT_FILE_COUNT Swift files)"
fi

if [ ! -f "Modules/libtailscale/module.modulemap" ]; then
    echo "❌ Modules/libtailscale/module.modulemap not found"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ Modules/libtailscale/module.modulemap"
fi

echo

if [ $ERRORS -gt 0 ]; then
    echo "❌ Setup completed with $ERRORS error(s)"
    exit 1
fi

echo "✅ TailscaleKit package ready!"
echo
echo "📝 Next steps:"
echo "   1. Test: swift build"
echo "   2. Use in your project"
echo
