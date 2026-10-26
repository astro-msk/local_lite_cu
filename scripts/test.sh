#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEVELOPER_DIR_PATH="$(xcode-select -p)"
TEST_FLAGS=(--disable-xctest)
# Standalone Command Line Tools bundle Swift Testing but do not expose its
# framework and macro plugin to SwiftPM automatically. Full Xcode does.
if [[ "$DEVELOPER_DIR_PATH" == */CommandLineTools ]]; then
  TEST_FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
  TEST_PLUGIN="$DEVELOPER_DIR_PATH/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
  if [[ -f "$TEST_PLUGIN" && -d "$TEST_FRAMEWORKS/Testing.framework" ]]; then
    TEST_FLAGS+=(
      -Xswiftc "-F$TEST_FRAMEWORKS"
      -Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN"
      -Xlinker "-F$TEST_FRAMEWORKS"
      -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS"
      -Xlinker -rpath -Xlinker "$DEVELOPER_DIR_PATH/Library/Developer/usr/lib"
    )
  fi
fi
swift test "${TEST_FLAGS[@]}"
swift run LiteCUCheck
