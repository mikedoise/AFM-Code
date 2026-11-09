#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR=$(mktemp -d /tmp/afm-tool-tests.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos27.0 \
  'AFM Code/AI/ToolStep.swift' 'AFM Code/AI/PreparedFileChange.swift' \
  'AFM Code/AI/ToolContext.swift' 'AFM Code/AI/ToolApprovalService.swift' \
  'AFM Code/AI/Tools/ReadFileTool.swift' 'AFM Code/AI/Tools/WriteFileTool.swift' \
  'AFM Code/AI/Tools/EditFileTool.swift' \
  scripts/ToolSafetyFixtures.swift scripts/ToolSafetyTests.swift \
  -o "$BUILD_DIR/tool-safety-tests"
"$BUILD_DIR/tool-safety-tests"
