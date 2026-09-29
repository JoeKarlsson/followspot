#!/usr/bin/env bash
# Run the Swift checks (macos/Tests/Checks.swift) against the app's non-UI
# sources. Plain swiftc, no test framework: Swift Testing and XCTest need
# Xcode, and this has to work with just the Command Line Tools.
#
#   macos/test.sh
set -euo pipefail

cd "$(dirname "$0")"
FILES=()
for name in AppSettings Models Paths Scripts Server Staging Updates; do
  FILES+=("Sources/Followspot/$name.swift")
done
mkdir -p .build/checks
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 "${FILES[@]}" Tests/Checks.swift \
  -o .build/checks/checks
.build/checks/checks
