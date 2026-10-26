#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ARC_TEST_BUILD="$(swift build --show-bin-path)"
if [[ ! -f "$ARC_TEST_BUILD/Modules/LiteCUCore.swiftmodule" ]]; then
  echo "Build the package before running Arc DOM checks." >&2
  exit 1
fi
ARC_TEST_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/LiteCU-ArcDOM.XXXXXX")"
trap 'rm -rf "$ARC_TEST_TEMP"' EXIT
# Compile the real driver only to call its pure script generators. The exporter
# never instantiates ArcBrowserDriver, so it cannot send Apple Events.
swiftc -parse-as-library -I "$ARC_TEST_BUILD/Modules" \
  Sources/LiteCU/ArcBrowserDriver.swift Tests/ArcDOM/ExportScripts.swift \
  "$ARC_TEST_BUILD"/LiteCUCore.build/*.o -o "$ARC_TEST_TEMP/export-scripts"
"$ARC_TEST_TEMP/export-scripts" > "$ARC_TEST_TEMP/scripts.json"
node Tests/ArcDOM/arc-dom.test.cjs "$ARC_TEST_TEMP/scripts.json"
node Tests/ArcDOM/apple-script.test.cjs "$ARC_TEST_TEMP/scripts.json"
