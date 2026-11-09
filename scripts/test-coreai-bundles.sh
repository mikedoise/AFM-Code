#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TEMP=$(mktemp -d /tmp/afm-coreai-tests.XXXXXX)
trap 'rm -rf "$TEMP"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 'AFM Code/AI/CoreAI/CoreAIBundleValidator.swift' scripts/CoreAIBundleTests.swift -o "$TEMP/tests"
"$TEMP/tests" "$@"
