#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

cd "$PROJECT_DIR/web/oscar-viewer" || exit 1

npm install
npm run build

cd "$PROJECT_DIR" || exit 1

./gradlew build -x test -x osgi

echo "Making shell scripts executable..."

find "$PROJECT_DIR" -maxdepth 1 -type f -name "*.sh" -exec chmod +x {} \;

if [ -d "$PROJECT_DIR/osh-node-oscar" ]; then
  find "$PROJECT_DIR/osh-node-oscar" -maxdepth 1 -type f -name "*.sh" -exec chmod +x {} \;
fi
