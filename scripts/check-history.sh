#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/litecu-history-build.XXXXXX")"
trap 'rm -rf "$CHECK_BUILD"' EXIT
# Compile the real model/store sources in isolation, without touching SwiftPM's
# app build or launching Lite CU. The check creates its own temporary data folder.
swiftc -swift-version 5 -parse-as-library -module-name LiteCUCore \
  -emit-module -emit-module-path "$CHECK_BUILD/LiteCUCore.swiftmodule" \
  -emit-object Sources/LiteCUCore/Models.swift -o "$CHECK_BUILD/Models.o"
swiftc -swift-version 5 -I "$CHECK_BUILD" Sources/LiteCU/RunHistoryStore.swift \
  scripts/HistoryPersistenceCheck.swift "$CHECK_BUILD/Models.o" -o "$CHECK_BUILD/check-history"
"$CHECK_BUILD/check-history"
