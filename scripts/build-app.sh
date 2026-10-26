#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product LiteCU
APP="$(pwd)/dist/Lite CU.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LiteCU "$APP/Contents/MacOS/LiteCU"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier local.litecu.app "$APP"
echo "Built $APP"
