#!/usr/bin/env python3
"""Optional signed, headless sandbox fixture. Does not launch AFM Code.
Builds a separate bundle with the same sandbox/network/file entitlements and
runs fixed Python/gh/git probes. No credential/config dump or network commands.
"""
from pathlib import Path
import os, plistlib, re, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
app=Path.home()/'Library/Developer/Xcode/DerivedData/AFM_Code-fqzbtgeazincglhbszoaohzhqxck/Build/Products/Debug/AFM Code.app'
details=subprocess.run(['codesign','-dvv',str(app)],capture_output=True,text=True,check=True).stderr
identity=next(x.split('=',1)[1] for x in details.splitlines() if x.startswith('Authority=Apple Development:'))
context=(root/'AFM Code/AI/ToolContext.swift').read_text()
a=context.index('    nonisolated private final class PipedCapture');b=context.index('    // MARK: - Formatting helpers',a)
runner='import Foundation\nimport Darwin\nstruct ToolContext { enum ToolError: Error { case io(String) }; struct ProcessRun: Sendable { var exitCode: Int32; var output: String; var timedOut: Bool }\n'+context[a:b]+'\n}\n'
with tempfile.TemporaryDirectory(prefix='afm-sandbox-probe-') as tmp:
    base=Path(tmp);bundle=base/'AFM Environment Probe.app';mac=bundle/'Contents/MacOS';mac.mkdir(parents=True)
    info={'CFBundleIdentifier':'app.techopolis.AFMEnvironmentProbe20261108','CFBundleName':'AFM Environment Probe',
          'CFBundleExecutable':'probe','CFBundlePackageType':'APPL','CFBundleVersion':'1','LSBackgroundOnly':True}
    (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    (base/'Runner.swift').write_text(runner)
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','6','-target','arm64-apple-macos27.0',str(base/'Runner.swift'),
        str(root/'AFM Code/AI/ShellEnvironment.swift'),str(root/'AFM Code/AI/EnvironmentDiagnostics.swift'),
        str(root/'scripts/EnvironmentSandboxProbe.swift'),'-o',str(mac/'probe')],check=True)
    (base/'LegacySandbox.entitlements').write_bytes(plistlib.dumps({'com.apple.security.app-sandbox':True,'com.apple.security.files.user-selected.read-write':True,'com.apple.security.network.client':True}))
    subprocess.run(['codesign','--force','--sign',identity,'--entitlements',str(base/'LegacySandbox.entitlements'),str(bundle)],check=True)
    subprocess.run(['codesign','--verify','--strict',str(bundle)],check=True)
    # A clean launch environment makes no secrets available to the fixture.
    env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LC_ALL':'C'}
    subprocess.run([str(mac/'probe')],env=env,check=True,timeout=90)
print('SIGNED SANDBOX FIXTURE COMPLETED; temporary bundle removed')
