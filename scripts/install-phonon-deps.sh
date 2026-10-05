#!/usr/bin/env bash
# Install Fermion + MLX for Phonon-2. Idempotent.
# Used by install-local-cli.sh and site/install.sh; also: parrot models install-runtime
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARROT="${PARROT_BIN:-}"

if [ -z "$PARROT" ]; then
  if [ -x "$ROOT/.build/release/parrot" ]; then
    PARROT="$ROOT/.build/release/parrot"
  elif [ -x "${HOME}/.local/lib/parrot/parrot" ]; then
    PARROT="${HOME}/.local/lib/parrot/parrot"
  elif command -v parrot >/dev/null 2>&1; then
    PARROT="$(command -v parrot)"
  fi
fi

if [ -n "$PARROT" ] && "$PARROT" models list 2>/dev/null | grep -q phonon-2; then
  echo "→ Phonon-2 runtime (fermion + MLX)…"
  "$PARROT" models install-runtime
  exit 0
fi

# Fallback when parrot is too old or missing the subcommand (curl install before app update).
find_python() {
  local p
  for p in python3.13 python3.12 python3.11 \
    /opt/homebrew/bin/python3.12 /usr/local/bin/python3.12 \
    /Library/Frameworks/Python.framework/Versions/3.12/bin/python3; do
    if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import sys; exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
      echo "$(command -v "$p" 2>/dev/null || echo "$p")"
      return 0
    fi
  done
  return 1
}

if command -v fermion >/dev/null 2>&1; then
  echo "✓ fermion already on PATH"
  exit 0
fi

PY="$(find_python)" || {
  echo "⚠  Phonon-2 needs Python 3.10+ and fermion-research." >&2
  echo "   Install python.org 3.12, then: parrot models install-runtime" >&2
  exit 0
}

echo "→ pip install fermion-research + MLX (via $PY)…"
"$PY" -m pip install --user fermion-research mlx mlx-audio mlx-lm soundfile scipy zstandard
echo "✓ done. Ensure ~/.local/bin is on PATH, then: parrot models download phonon-2"
