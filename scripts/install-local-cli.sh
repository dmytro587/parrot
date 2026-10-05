#!/usr/bin/env bash
# Build release parrot from this repo and install to PATH.
# Layout: $PREFIX/parrot + $PREFIX/Sparkle.framework, symlink at $LINK.
#
# For Parrot.app (menu bar, signed bundle, /Applications), use scripts/dev-install.sh.
# This script is for a standalone CLI tree under PREFIX without installing the .app.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_DIR="$(swift build -c release --product parrot --show-bin-path)"
BIN="$BIN_DIR/parrot"
LINK="${PARROT_LINK:-/usr/local/bin/parrot}"
PREFIX="${PARROT_PREFIX:-/usr/local/lib/parrot}"

echo "→ building release parrot"
swift build -c release --product parrot
test -x "$BIN" || { echo "build failed: $BIN" >&2; exit 1; }
test -d "$BIN_DIR/Sparkle.framework" || { echo "missing Sparkle.framework in $BIN_DIR" >&2; exit 1; }

install_tree() {
  local dest="$1"
  mkdir -p "$dest"
  install -m 755 "$BIN" "$dest/parrot"
  rm -rf "$dest/Sparkle.framework"
  ditto "$BIN_DIR/Sparkle.framework" "$dest/Sparkle.framework"
}

link_bin() {
  local target="$1"
  mkdir -p "$(dirname "$LINK")"
  ln -sfn "$target/parrot" "$LINK"
}

if [ -w "$(dirname "$LINK")" ] 2>/dev/null && [ -w "$(dirname "$PREFIX")" ] 2>/dev/null; then
  echo "→ installing to $PREFIX, link $LINK"
  install_tree "$PREFIX"
  link_bin "$PREFIX"
else
  echo "→ need sudo for $PREFIX and $LINK"
  if ! sudo -n true 2>/dev/null; then
    PREFIX="${HOME}/.local/lib/parrot"
    LINK="${HOME}/.local/bin/parrot"
    echo "→ sudo unavailable; using $PREFIX and $LINK"
    echo "  put ~/.local/bin before /usr/local/bin on PATH to override the old parrot"
    mkdir -p "$(dirname "$PREFIX")" "$(dirname "$LINK")"
    install_tree "$PREFIX"
    link_bin "$PREFIX"
    if [ -x /usr/local/bin/parrot ] && ! /usr/local/bin/parrot models list 2>/dev/null | grep -q whistle; then
      echo ""
      echo "⚠  /usr/local/bin/parrot is still the old release (no Whistle)."
      echo "   Open a new terminal, then:  which parrot   → should be $LINK"
      echo "   Or replace the system binary:"
      echo "     sudo ln -sfn $PREFIX/parrot /usr/local/bin/parrot"
      echo "   (Sparkle lives in $PREFIX; use that path, not a copy into /usr/local/bin.)"
    fi
    exit 0
  fi
  sudo mkdir -p "$PREFIX" "$(dirname "$LINK")"
  sudo install -m 755 "$BIN" "$PREFIX/parrot"
  sudo rm -rf "$PREFIX/Sparkle.framework"
  sudo ditto "$BIN_DIR/Sparkle.framework" "$PREFIX/Sparkle.framework"
  sudo ln -sfn "$PREFIX/parrot" "$LINK"
fi

echo "✓ $LINK → $(readlink "$LINK" 2>/dev/null || echo "$LINK")"
"$LINK" --version 2>/dev/null || true
