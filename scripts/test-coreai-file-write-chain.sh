#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${1:?Usage: bash scripts/test-coreai-file-write-chain.sh /path/to/AFM_Code-DerivedData}"
BUILD_DIR=$(mktemp -d /tmp/afm-coreai-file-chain.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT
# Reuse the exact deterministic parser/dispatch executor from session tests,
# excluding its separate @main. No model is loaded or inference requested.
python3 - "$BUILD_DIR/ScriptedGemmaFixtures.swift" <<'PY'
from pathlib import Path
import sys
source = Path('scripts/CoreAIToolSessionTests.swift').read_text()
marker = '@main struct CoreAIToolSessionTests {'
assert source.count(marker) == 1
Path(sys.argv[1]).write_text(source.split(marker)[0])
PY
python3 scripts/build-coreai-smoke.py "$1" "$BUILD_DIR/tests" \
  'AFM Code/AI/ToolStep.swift' 'AFM Code/AI/PreparedFileChange.swift' \
  'AFM Code/AI/ToolContext.swift' 'AFM Code/AI/ToolApprovalService.swift' \
  'AFM Code/AI/Tools/ReadFileTool.swift' 'AFM Code/AI/Tools/WriteFileTool.swift' \
  scripts/ToolSafetyFixtures.swift "$BUILD_DIR/ScriptedGemmaFixtures.swift" \
  scripts/CoreAIFileWriteChainTests.swift
"$BUILD_DIR/tests"
