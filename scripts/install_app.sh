#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="see-your-usage"
SOURCE_APP="$ROOT_DIR/.build/release/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"

"$ROOT_DIR/scripts/build_app.sh" >/dev/null
mkdir -p "$INSTALL_DIR"

# Stop only this installed bundle after a successful build. Otherwise `open` can
# activate the old process while the user believes the new version is running.
for app_pid in $(pgrep -x "$APP_NAME" || true); do
  executable_path="$(ps -p "$app_pid" -o comm= || true)"
  if [[ "$executable_path" == "$TARGET_APP/Contents/MacOS/$APP_NAME" ]]; then
    kill "$app_pid" 2>/dev/null || true
    for attempt in {1..30}; do
      kill -0 "$app_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$app_pid" 2>/dev/null; then
      echo "Please quit $APP_NAME before installing the update." >&2
      exit 1
    fi
  fi
done

rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
touch "$TARGET_APP"

if command -v mdimport >/dev/null 2>&1; then
  mdimport "$TARGET_APP" >/dev/null 2>&1 || true
fi

echo "$TARGET_APP"
