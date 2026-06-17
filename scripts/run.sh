#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$("$ROOT_DIR/scripts/install_app.sh")"

open "$APP_PATH"
echo "Started $APP_PATH"
