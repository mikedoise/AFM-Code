#!/usr/bin/env python3
"""Production diagnostics, approvals and fixed probes with isolated HOME.
Never opens user app data, runs model inference, or performs network/auth calls.
"""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='afm-environment-tests-') as tmp:
    base=Path(tmp); home=base/'home';home.mkdir(); work=base/'work';work.mkdir()
    fixtures=(root/'scripts/ToolSafetyFixtures.swift').read_text()
    a=fixtures.index('enum ShellEnvironment {');b=fixtures.index('@MainActor final class ToolSafetyFixture',a)
    fixtures=fixtures[:a]+fixtures[b:]
    (base/'Fixtures.swift').write_text(fixtures)
    files=['AI/ToolStep.swift','AI/PreparedFileChange.swift','AI/ToolContext.swift','AI/ToolApprovalService.swift',
           'AI/ShellEnvironment.swift','AI/EnvironmentDiagnostics.swift','AI/Tools/EnvironmentCheckTool.swift']
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','6','-target','arm64-apple-macos27.0',
        *[str(root/'AFM Code'/f) for f in files],str(base/'Fixtures.swift'),str(root/'scripts/EnvironmentDiagnosticsTests.swift'),'-o',str(base/'tests')],check=True)
    env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(home),'CFFIXED_USER_HOME':str(home),'ZDOTDIR':str(home),'TMPDIR':str(base),'LC_ALL':'C'}
    subprocess.run([str(base/'tests'),str(work)],env=env,check=True,timeout=60)
print('ALL ENVIRONMENT DIAGNOSTICS FIXTURE TESTS PASSED')
