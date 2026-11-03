#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
RELEASE_DIR="$PROJECT_ROOT/dist"
APP_PATH="$RELEASE_DIR/GamePulse.app"
ARCHIVE_PATH="$RELEASE_DIR/GamePulse-macOS-universal-v1.0.0.zip"
CHECKSUM_PATH="$RELEASE_DIR/GamePulse-macOS-universal-v1.0.0.sha256"

"$PROJECT_ROOT/scripts/package_app.sh"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
cd "$RELEASE_DIR"
shasum -a 256 "${ARCHIVE_PATH:t}" > "${CHECKSUM_PATH:t}"

echo "$ARCHIVE_PATH"
echo "$CHECKSUM_PATH"
