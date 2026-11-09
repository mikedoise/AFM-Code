#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR=$(mktemp -d /tmp/afm-edit-tests.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 \
  'AFM Code/AI/ToolStep.swift' 'AFM Code/AI/PreparedFileChange.swift' \
  scripts/PreparedFileChangeTests.swift -o "$BUILD_DIR/afm-edit-tests"
"$BUILD_DIR/afm-edit-tests"
