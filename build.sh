#!/bin/bash
set -e

NIX_FILE="adaptixc2.nix"

# Check requirements
command -v nix >/dev/null || { echo "Nix not found"; exit 1; }
[ -f "$NIX_FILE" ] || { echo "$NIX_FILE not found"; exit 1; }

# Get drivers.csv hash
echo "Fetching drivers.csv hash..."
DRIVERS_HASH=$(nix-prefetch-url https://www.loldrivers.io/api/drivers.csv 2>/dev/null)
[ -n "$DRIVERS_HASH" ] || { echo "Failed to fetch hash"; exit 1; }

# Update Nix file
cp "$NIX_FILE" "$NIX_FILE.backup"
sed -i '/url = "https:\/\/www\.loldrivers\.io\/api\/drivers\.csv";/,/sha256 = / {
    s/sha256 = "[^"]*";/sha256 = "'"$DRIVERS_HASH"'";/
}' "$NIX_FILE"

# Build
echo "Building..."
nix-build "$NIX_FILE" || { echo "Build failed"; exit 1; }

echo "Done. Result: $(readlink result)"
