#!/bin/bash
# Setup script for TailscaleKit without Xcode
# This script copies TailscaleKit Swift sources and builds the C library

set -e

echo "🔷 Setting up TailscaleKit without Xcode..."
echo

# Check for Go
if ! command -v go &> /dev/null; then
    echo "❌ Go is required to build libtailscale"
    echo "   Install from: https://go.dev/dl/"
    exit 1
fi

echo "✅ Go found: $(go version)"
echo

# Clone libtailscale if not already present
LIBTAILSCALE_DIR="${LIBTAILSCALE_DIR:-/tmp/libtailscale}"

if [ ! -d "$LIBTAILSCALE_DIR" ]; then
    echo "📥 Cloning libtailscale..."
    git clone https://github.com/tailscale/libtailscale.git "$LIBTAILSCALE_DIR"
    echo
else
    echo "✅ libtailscale already cloned at $LIBTAILSCALE_DIR"
    echo
fi

# Build C library
echo "🔨 Building libtailscale.a (this may take a minute)..."
cd "$LIBTAILSCALE_DIR"
make c-archive

if [ ! -f "libtailscale.a" ]; then
    echo "❌ Failed to build libtailscale.a"
    exit 1
fi

echo "✅ libtailscale.a built successfully"
echo

# Return to project directory
cd - > /dev/null

# Create directories
echo "📁 Creating project directories..."
mkdir -p TailscaleKit/LocalAPI
mkdir -p Modules/libtailscale
mkdir -p lib
mkdir -p include

# Copy TailscaleKit Swift sources
echo "📋 Copying TailscaleKit Swift sources..."
cp "$LIBTAILSCALE_DIR/swift/TailscaleKit"/*.swift TailscaleKit/ 2>/dev/null || true
cp "$LIBTAILSCALE_DIR/swift/TailscaleKit/LocalAPI"/*.swift TailscaleKit/LocalAPI/ 2>/dev/null || true

SWIFT_FILE_COUNT=$(find TailscaleKit -name "*.swift" | wc -l)
echo "   Copied $SWIFT_FILE_COUNT Swift files"

# Copy C library and header
echo "📚 Copying C library and headers..."
cp "$LIBTAILSCALE_DIR/libtailscale.a" lib/
cp "$LIBTAILSCALE_DIR/tailscale.h" include/

# Create module map
echo "🗺️  Creating module map..."
cat > Modules/libtailscale/module.modulemap <<'EOF'
module libtailscale {
    header "../../include/tailscale.h"
    link "tailscale"
    export *
}
EOF

# Verify setup
echo
echo "🔍 Verifying setup..."
echo

ERRORS=0

if [ ! -f "lib/libtailscale.a" ]; then
    echo "❌ lib/libtailscale.a not found"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ lib/libtailscale.a"
fi

if [ ! -f "include/tailscale.h" ]; then
    echo "❌ include/tailscale.h not found"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ include/tailscale.h"
fi

if [ ! -f "Modules/libtailscale/module.modulemap" ]; then
    echo "❌ Modules/libtailscale/module.modulemap not found"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ Modules/libtailscale/module.modulemap"
fi

if [ ! -f "TailscaleKit/TailscaleNode.swift" ]; then
    echo "❌ TailscaleKit/TailscaleNode.swift not found"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ TailscaleKit/*.swift ($SWIFT_FILE_COUNT files)"
fi

echo

if [ $ERRORS -gt 0 ]; then
    echo "❌ Setup completed with $ERRORS error(s)"
    exit 1
fi

echo "✅ Setup complete!"
echo
echo "📝 Next steps:"
echo "   1. Update Package.swift to include TailscaleKit target"
echo "   2. Run: swift build"
echo "   3. Import TailscaleKit in your Swift code"
echo
echo "📖 See TAILSCALE_WITHOUT_XCODE.md for detailed instructions"
