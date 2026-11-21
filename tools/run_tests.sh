#!/bin/zsh
# Runs the unit tests (Swift Testing).
# With only the Command Line Tools installed (no Xcode), the compiler doesn't find the Testing macro plugin by
# itself, so it is passed explicitly. With Xcode selected, a plain `swift test` works and nothing is added.
set -e
cd "$(dirname "$0")/.."
PLUGIN="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" && -f "$PLUGIN" ]]; then
  swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" "$@"
else
  swift test "$@"
fi
