#!/bin/bash
set -e

VERSION=${1:-"0.2.0"}
RELEASE_DIR="release-$VERSION"

echo "Building Sweeper v$VERSION..."

# Clean previous release
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

# Build targets
declare -A TARGETS=(
    ["macos-arm64"]="aarch64-macos"
    ["macos-x64"]="x86_64-macos"
    ["linux-x64"]="x86_64-linux-gnu"
    ["windows-x64"]="x86_64-windows-gnu"
)

for name in "${!TARGETS[@]}"; do
    target="${TARGETS[$name]}"
    echo "Building for $name ($target)..."
    
    # Build GUI
    zig build -Dtarget=$target -Doptimize=ReleaseFast 2>/dev/null || {
        echo "Warning: Failed to build for $target, skipping..."
        continue
    }
    
    # Create release package
    pkg_dir="$RELEASE_DIR/sweeper-$name"
    mkdir -p "$pkg_dir"
    
    if [[ "$name" == *"windows"* ]]; then
        cp zig-out/bin/sweeper-gui.exe "$pkg_dir/" 2>/dev/null || true
        cp zig-out/bin/sweeper.exe "$pkg_dir/" 2>/dev/null || true
        # Copy resources
        cp -r resources "$pkg_dir/" 2>/dev/null || true
        cp README.md LICENSE "$pkg_dir/"
        # Create zip
        (cd "$RELEASE_DIR" && zip -r "sweeper-$name.zip" "sweeper-$name")
    else
        cp zig-out/bin/sweeper-gui "$pkg_dir/" 2>/dev/null || true
        cp zig-out/bin/sweeper "$pkg_dir/" 2>/dev/null || true
        # Copy resources
        cp -r resources "$pkg_dir/" 2>/dev/null || true
        cp README.md LICENSE "$pkg_dir/"
        # Create tarball
        (cd "$RELEASE_DIR" && tar -czvf "sweeper-$name.tar.gz" "sweeper-$name")
    fi
    
    # Cleanup temp dir
    rm -rf "$pkg_dir"
    
    echo "Created: $RELEASE_DIR/sweeper-$name.*"
done

echo ""
echo "Release builds complete in $RELEASE_DIR/"
ls -la "$RELEASE_DIR/"
