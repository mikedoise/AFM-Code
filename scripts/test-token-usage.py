#!/usr/bin/env python3
"""Test production usage persistence and Foundation Models accounting in a temporary directory."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="afm-token-usage-") as directory:
    binary = Path(directory) / "tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-target", "arm64-apple-macos27.0",
        str(root / "AFM Code/Models/ModelDescriptor.swift"), str(root / "AFM Code/App/DesktopStorage.swift"),
        str(root / "AFM Code/App/TokenUsageStore.swift"), str(root / "scripts/TokenUsageTests.swift"),
        "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
engine = (root / "AFM Code/AI/SessionEngine.swift").read_text()
assert engine.count("TokenUsageStore.shared.begin(model: activeModel, purpose:") == 2
assert engine.count("defer { TokenUsageStore.shared.finishUnreported(usageAttempt) }") == 2
assert engine.count("inputBefore: usageBefore.input.totalTokenCount, outputBefore: usageBefore.output.totalTokenCount") == 2
assert "inputAfter: languageModelSession.usage.input.totalTokenCount" in engine
assert "inputAfter: summarizer.usage.input.totalTokenCount" in engine
assert "message.tokenCount = response.usage.output.totalTokenCount" in engine
assert "UsageSettingsSection()" in (root / "AFM Code/Features/Settings/SettingsView.swift").read_text()
print("PASS source wiring: normal responses, summaries, pinned model and Settings (not GUI validation)")
