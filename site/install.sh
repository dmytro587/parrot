#!/usr/bin/env bash
# Parrot installer, for people who prefer a terminal to the DMG.
#   curl -fsSL https://perroquet.xyz/install.sh | sh
#
# Downloads the latest Parrot DMG from GitHub Releases, checks it against
# the published SHA-256, copies Parrot.app to /Applications (or
# ~/Applications), links /usr/local/bin/parrot to it, and opens it. The app
# is signed and notarized, so Gatekeeper opens it without an override and
# nothing strips the quarantine attribute.
#
# Apple Silicon only: WhisperKit runs on the Apple Neural Engine via CoreML.

set -euo pipefail

REPO="humanitas-labs/parrot"
ASSET="Parrot.dmg"
LINK="/usr/local/bin/parrot"

red()    { printf "\033[31m%s\033[0m\n" "$*" >&2; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
dim()    { printf "\033[2m%s\033[0m\n" "$*"; }

# 1. sanity
if [ "$(uname -s)" != "Darwin" ]; then
    red "parrot is macOS-only (detected $(uname -s))"
    exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    red "parrot requires Apple Silicon (detected $ARCH)"
    red "the on-device inference engine uses the Apple Neural Engine, which Intel Macs don't have."
    exit 1
fi

for cmd in curl shasum hdiutil ditto; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        red "missing dependency: $cmd"
        exit 1
    fi
done

# 2. resolve latest release
dim "→ resolving latest release..."
TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -E '"tag_name"' \
    | head -1 \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')

if [ -z "${TAG:-}" ]; then
    red "couldn't determine latest release tag"
    exit 1
fi
dim "  ${TAG}"

BASE="https://github.com/${REPO}/releases/download/${TAG}"

# 3. download and verify
TMP=$(mktemp -d)
MOUNT=""
cleanup() {
    [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

dim "→ downloading ${ASSET}..."
curl -fsSL "${BASE}/${ASSET}" -o "$TMP/${ASSET}"
curl -fsSL "${BASE}/${ASSET}.sha256" -o "$TMP/${ASSET}.sha256"

dim "→ verifying checksum..."
EXPECTED=$(awk '{print $1}' "$TMP/${ASSET}.sha256")
ACTUAL=$(shasum -a 256 "$TMP/${ASSET}" | awk '{print $1}')
if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
    red "checksum mismatch for ${ASSET}"
    red "  expected ${EXPECTED:-<empty>}"
    red "  got      ${ACTUAL}"
    red "not installing. try again, or download the DMG from https://github.com/${REPO}/releases"
    exit 1
fi

# 4. copy the app out of the DMG
MOUNT="$TMP/mnt"
mkdir -p "$MOUNT"
hdiutil attach "$TMP/${ASSET}" -nobrowse -readonly -quiet -mountpoint "$MOUNT"

if [ -w /Applications ]; then
    APPS=/Applications
else
    APPS="$HOME/Applications"
    mkdir -p "$APPS"
fi
DEST="$APPS/Parrot.app"

if pgrep -x parrot >/dev/null 2>&1 && [ -d "$DEST" ]; then
    dim "→ quitting the running Parrot..."
    osascript -e 'quit app id "com.humanitas.parrot"' >/dev/null 2>&1 || true
    sleep 1
fi

dim "→ installing to ${DEST}..."
rm -rf "$DEST"
ditto "$MOUNT/Parrot.app" "$DEST"
hdiutil detach "$MOUNT" -quiet
MOUNT=""

# 5. the parrot command: a link into the app. Never replace a separate
#    binary (an old CLI install) without asking.
EXE="$DEST/Contents/MacOS/parrot"
REPLACE=1
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
    REPLACE=0
    if [ -r /dev/tty ]; then
        printf '%s is a separate parrot binary from an earlier install. Replace it with a link to Parrot.app? [y/N] ' "$LINK"
        read -r answer < /dev/tty || answer=""
        case "$answer" in y|Y|yes) REPLACE=1 ;; esac
    fi
    [ "$REPLACE" = 1 ] || dim "  left ${LINK} as it was; Parrot.app offers to replace it when it opens."
fi
if [ "$REPLACE" = 1 ]; then
    dim "→ linking ${LINK}..."
    LINK_DIR="$(dirname "$LINK")"
    mkdir -p "$LINK_DIR" 2>/dev/null || sudo mkdir -p "$LINK_DIR"
    SUDO=""
    [ -w "$LINK_DIR" ] || SUDO="sudo"
    $SUDO ln -sfn "$EXE" "$LINK"
fi

# 6. open it: the first launch moves off an old LaunchAgent and asks for
#    the microphone and Accessibility in Parrot's name.
open "$DEST"

green "✓ Parrot ${TAG} installed at ${DEST}"
echo
if [ "${PARROT_SKIP_PHONON_DEPS:-0}" != 1 ]; then
  dim "→ Phonon-2 runtime (fermion + MLX, optional)…"
  if "$EXE" models install-runtime 2>/dev/null; then
    :
  elif command -v fermion >/dev/null 2>&1; then
    green "✓ fermion already on PATH"
  else
    PY=""
    for p in python3.12 python3.13 python3.11; do
      if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import sys; exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
        PY="$(command -v "$p")"
        break
      fi
    done
    if [ -n "$PY" ]; then
      "$PY" -m pip install --user fermion-research mlx mlx-audio mlx-lm soundfile scipy zstandard || true
      dim '  add ~/.local/bin to PATH if fermion is not found'
    else
      dim "  install Python 3.12+, then: parrot models install-runtime"
    fi
  fi
fi
echo "next:"
echo "  allow Microphone and Accessibility for Parrot when macOS asks"
echo "  parrot models download phonon-2   # if you use Phonon-2 (weights ~164 MB)"
echo "  parrot install --launch-at-login   # (optional) start at login"
