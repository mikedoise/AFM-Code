#!/usr/bin/env python3
"""Real Git + production tool regressions in disposable local fixtures only.
No network, user repository, user Git config, model, GUI or SwiftData access.
"""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
real_git = subprocess.check_output(['xcrun', '--find', 'git'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='afm-git-tests-') as temporary:
    base = Path(temporary)
    home = base/'home'; home.mkdir()
    (home/'.zprofile').write_text('export PATH=/usr/bin:/bin\n')
    templates = base/'empty-templates'; templates.mkdir()
    remote = base/'remote.git'; seed = base/'seed'; work = base/'work'
    env = {
        'PATH': str(Path(real_git).parent)+':/usr/bin:/bin:/usr/sbin:/sbin',
        'HOME': str(home), 'ZDOTDIR': str(home), 'XDG_CONFIG_HOME': str(home),
        'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
        'GIT_ALLOW_PROTOCOL': 'file', 'GIT_TERMINAL_PROMPT': '0',
        'GIT_AUTHOR_NAME':'AFM Fixture', 'GIT_AUTHOR_EMAIL':'fixture@example.invalid',
        'GIT_COMMITTER_NAME':'AFM Fixture', 'GIT_COMMITTER_EMAIL':'fixture@example.invalid',
        'GIT_TEMPLATE_DIR':str(templates), 'AFM_TEST_REAL_GIT':real_git,
        'LC_ALL':'C', 'TMPDIR':str(base),
    }
    def git(*args, cwd=None):
        return subprocess.check_output([real_git, *args], cwd=cwd or base, env=env, stderr=subprocess.STDOUT, text=True).strip()
    git('init', '--bare', '--initial-branch=main', str(remote))
    git('init', '--initial-branch=main', str(seed))
    for name in ['sample.txt', '-dash.txt', "quote's file.txt"]:
        (seed/name).write_text('initial\n')
    git('add', '.', cwd=seed); git('commit', '-m', 'Initial fixture', cwd=seed)
    git('remote','add','origin',str(remote),cwd=seed); git('push','-u','origin','main',cwd=seed)
    git('clone',str(remote),str(work))
    (seed/'sample.txt').write_text('remote change\n')
    git('add','sample.txt',cwd=seed); git('commit','-m','Remote fixture update',cwd=seed); git('push',cwd=seed)
    (base/'expected-head').write_text(git('rev-parse','HEAD',cwd=seed))
    (base/'nonrepo').mkdir()
    fixtures = (root/'scripts/ToolSafetyFixtures.swift').read_text()
    start = fixtures.index('enum ShellEnvironment {')
    end = fixtures.index('@MainActor final class ToolSafetyFixture', start)
    fixtures = fixtures[:start] + '''enum ShellEnvironment {
    static func inspectionSnapshot() -> (environment: [String: String], summary: String) { (ProcessInfo.processInfo.environment, "Fixture") }
    static func developerUSRBIN() -> String? { URL(fileURLWithPath: ProcessInfo.processInfo.environment["AFM_TEST_REAL_GIT"]!).deletingLastPathComponent().path }
    static func resolved() async -> [String: String]? { ProcessInfo.processInfo.environment }
}
'''
    (base/'Fixtures.swift').write_text(fixtures)
    files = ['AI/ToolStep.swift','AI/PreparedFileChange.swift','AI/ToolContext.swift',
             'AI/ToolApprovalService.swift','AI/EnvironmentDiagnostics.swift','AI/Tools/ReadFileTool.swift','AI/Tools/RunCommandTool.swift',
             'AI/Tools/GitTool.swift','AI/AgentInstructions.swift']
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','6','-target','arm64-apple-macos27.0',
                    *[str(root/'AFM Code'/f) for f in files],str(base/'Fixtures.swift'),
                    str(root/'scripts/GitCommandTests.swift'),'-o',str(base/'tests')],check=True)
    subprocess.run([str(base/'tests'),str(base)],env=env,check=True,timeout=90)
print('ALL GIT TOOL TESTS PASSED; temporary local repositories removed')
