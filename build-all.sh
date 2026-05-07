#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
RELEASE_VERSION="3.5.1"
DIST_DIR="$PROJECT_DIR/build/distributions"
STANDARD_ZIP="$DIST_DIR/oscar-${RELEASE_VERSION}.zip"

echo "Making shell scripts executable..."
find "$PROJECT_DIR" -type f -name "*.sh" -exec chmod +x {} +

cd "$PROJECT_DIR/web/oscar-viewer"
npm install
npm run build

cd "$PROJECT_DIR"
./gradlew build -x test -x osgi

if [ -d "$DIST_DIR" ]; then
  GENERATED_ZIP="$(find "$DIST_DIR" -maxdepth 1 -type f -name "*.zip" ! -name "oscar-${RELEASE_VERSION}.zip" -printf "%T@ %p\n" | sort -nr | awk 'NR==1 {print $2}')"
  if [ -n "$GENERATED_ZIP" ] && [ -f "$GENERATED_ZIP" ]; then
    cp -f "$GENERATED_ZIP" "$STANDARD_ZIP"
    echo "Standardized release zip: $STANDARD_ZIP"
  elif [ -f "$STANDARD_ZIP" ]; then
    echo "Release zip already available at: $STANDARD_ZIP"
  else
    echo "Warning: no distribution zip found under $DIST_DIR" >&2
  fi
else
  echo "Warning: distribution directory not found: $DIST_DIR" >&2
fi
