#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex Usage"
SOURCE_APP="$ROOT_DIR/.build/release/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"

"$ROOT_DIR/scripts/build_app.sh" >/dev/null
mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
touch "$TARGET_APP"

if command -v mdimport >/dev/null 2>&1; then
  mdimport "$TARGET_APP" >/dev/null 2>&1 || true
fi

echo "$TARGET_APP"
