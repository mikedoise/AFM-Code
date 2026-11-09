#!/usr/bin/env python3
"""Compile production model resolution/status, without app or model execution."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='afm-model-status-') as directory:
    binary = Path(directory)/'tests'
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','6',
        str(root/'AFM Code/Models/ModelDescriptor.swift'),str(root/'AFM Code/Models/ModelStatus.swift'),
        str(root/'scripts/ModelStatusTests.swift'),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True,timeout=10)
# Source wiring guards complement, but do not replace, GUI/VoiceOver testing.
source = root/'AFM Code'
badge = (source/'Support/ModelBadgeView.swift').read_text()
assert 'catalog.activeDescriptor' not in badge and 'let status: ModelStatus' in badge
assert '.accessibilityLabel(status.accessibilityLabel)' in badge
composer = (source/'Features/Chat/ComposerView.swift').read_text()
assert 'ModelBadgeView(status: engine?.modelStatus' in composer
assert 'catalog.activeDescriptor' not in composer
sidebar = (source/'Features/Sidebar/SessionSidebarView.swift').read_text()
assert 'ModelBadgeView(status: selectedModelStatus)' in sidebar and 'existingEngine(forSessionID: id)' in sidebar
for file in ['Features/Chat/ChatView.swift','Features/Chat/MessageListView.swift']:
    assert 'catalog.activeDescriptor' not in (source/file).read_text()
engine = (source/'AI/SessionEngine.swift').read_text()
assert 'lastAttemptedModelID == model?.id ? errorMessage : nil' in engine
assert 'turnModel = selectedModel' in engine and 'turnModel = nil' in engine
assert 'message.modelID = activeModel?.id' in engine
print('PASS source wiring: per-session badges/title, scoped error and pinned message identity (not GUI validation)')
