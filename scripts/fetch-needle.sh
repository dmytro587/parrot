#!/usr/bin/env bash
# Fetches the Needle engine (libneedle.a + needle.h) for macOS Apple Silicon.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE="https://huggingface.co/Cactus-Compute/needle3/resolve/main/macos-arm64"
mkdir -p Vendor/needle/lib
curl -fsSL "$BASE/needle.h" -o Sources/CNeedle/include/needle.h
curl -fsSL "$BASE/libneedle.a" -o Vendor/needle/lib/libneedle.a
echo "✓ Needle engine updated ($(wc -c < Vendor/needle/lib/libneedle.a) bytes)"
