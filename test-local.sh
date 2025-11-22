#!/bin/bash
# Test script to run two Cuple instances on one machine

set -e

echo "🧪 Cuple Local Testing Script"
echo "=============================="
echo ""

# Build if needed
if [ ! -f ".build/debug/Cuple" ]; then
    echo "📦 Building Cuple..."
    make build
fi

echo "This script helps you test Cuple on a single machine."
echo ""
echo "Instructions:"
echo "1. First instance will start in this terminal"
echo "2. Open a new terminal and run: .build/debug/Cuple"
echo "3. In first instance: Click 'Start Sharing'"
echo "4. In second instance: Click 'Browse Shares...'"
echo "5. You should see the first instance listed!"
echo ""
echo "Note: Both instances will use Tailscale ephemeral nodes,"
echo "so they'll appear as separate devices on your tailnet."
echo ""
read -p "Press Enter to start first instance..."

# Run first instance
echo "🚀 Starting Cuple instance 1..."
.build/debug/Cuple
