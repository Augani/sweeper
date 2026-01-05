#!/bin/bash
# Test script to run the TUI in a proper terminal

cd "$(dirname "$0")"

# Build the project
echo "Building..."
zig build || exit 1

echo ""
echo "Launching TUI..."
echo "Press 'q' to quit"
echo ""

# Run in a terminal
./zig-out/bin/desktop-cleanup --tui
