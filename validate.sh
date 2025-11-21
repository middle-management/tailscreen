#!/bin/bash
# Validation script for Cuple structure

echo "🔍 Validating Cuple project structure..."
echo ""

# Check Package.swift exists
if [ -f "Package.swift" ]; then
    echo "✅ Package.swift found"
else
    echo "❌ Package.swift missing"
    exit 1
fi

# Check all required source files
REQUIRED_FILES=(
    "Sources/CupleApp.swift"
    "Sources/AppState.swift"
    "Sources/MenuBarView.swift"
    "Sources/NetworkHelper.swift"
    "Sources/ScreenCapture.swift"
    "Sources/ScreenShareServer.swift"
    "Sources/ScreenShareClient.swift"
    "Sources/VideoEncoder.swift"
    "Sources/VideoDecoder.swift"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "✅ $file"
    else
        echo "❌ $file missing"
        exit 1
    fi
done

echo ""
echo "📊 Project Statistics:"
echo "   Total Swift files: $(find Sources -name "*.swift" | wc -l)"
echo "   Total lines of code: $(find Sources -name "*.swift" -exec wc -l {} + | tail -1 | awk '{print $1}')"

echo ""
echo "🔍 Checking for common issues..."

# Check for @main
if grep -q "@main" Sources/CupleApp.swift; then
    echo "✅ @main entry point found"
else
    echo "❌ @main entry point missing"
fi

# Check imports
echo ""
echo "📦 Checking critical imports..."
grep -h "^import " Sources/*.swift | sort -u | while read -r line; do
    echo "   $line"
done

echo ""
echo "✅ Structure validation complete!"
echo ""
echo "⚠️  Note: This code requires macOS 13.0+ to build and run"
echo "   Required frameworks: ScreenCaptureKit, VideoToolbox, SwiftUI, AppKit"
echo ""
echo "To build on macOS:"
echo "   swift build -c release"
