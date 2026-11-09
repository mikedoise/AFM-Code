#!/usr/bin/env python3
"""Signed hardened desktop fixture; no App Sandbox, credentials, network or GUI.
Uses a temporary HOME and generated script, never user project/app data.
"""
from pathlib import Path
import os, plistlib, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
app=Path.home()/'Library/Developer/Xcode/DerivedData/AFM_Code-fqzbtgeazincglhbszoaohzhqxck/Build/Products/Debug/AFM Code.app'
details=subprocess.run(['codesign','-dvv',str(app)],capture_output=True,text=True,check=True).stderr
identity=next(x.split('=',1)[1] for x in details.splitlines() if x.startswith('Authority=Apple Development:'))
context=(root/'AFM Code/AI/ToolContext.swift').read_text();a=context.index('    nonisolated private final class PipedCapture');b=context.index('    // MARK: - Formatting helpers',a)
runner='import Foundation\nimport Darwin\nstruct ToolContext { enum ToolError: Error { case io(String) }; struct ProcessRun: Sendable { var exitCode:Int32;var output:String;var timedOut:Bool }\n'+context[a:b]+'\n}\n'
with tempfile.TemporaryDirectory(prefix='afm-desktop-probe-') as tmp:
 base=Path(tmp);home=base/'home';home.mkdir();work=base/'work';work.mkdir()
 (home/'.zprofile').write_text('export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\n')
 (work/'generated script.py').write_text("print('AFM_PYTHON_OK Python 1.0.0')\n")
 bundle=base/'AFM Desktop Probe.app';mac=bundle/'Contents/MacOS';mac.mkdir(parents=True)
 (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'app.techopolis.AFMDesktopProbe20261108','CFBundleExecutable':'probe','CFBundlePackageType':'APPL','CFBundleVersion':'1','LSBackgroundOnly':True}))
 (base/'Runner.swift').write_text(runner)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','6','-target','arm64-apple-macos27.0',str(base/'Runner.swift'),str(root/'AFM Code/AI/ShellEnvironment.swift'),str(root/'AFM Code/AI/EnvironmentDiagnostics.swift'),str(root/'scripts/EnvironmentDesktopProbe.swift'),'-o',str(mac/'probe')],check=True)
 subprocess.run(['codesign','--force','--sign',identity,'--options','runtime','--entitlements',str(root/'AFM Code/AFM Code.entitlements'),str(bundle)],check=True)
 subprocess.run(['codesign','--verify','--strict',str(bundle)],check=True)
 signed=subprocess.run(['codesign','-dvv',str(bundle)],capture_output=True,text=True,check=True).stderr
 assert 'runtime' in signed
 env={'PATH':'/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(home),'CFFIXED_USER_HOME':str(home),'ZDOTDIR':str(home),'TMPDIR':str(base),'LC_ALL':'C','GH_NO_UPDATE_NOTIFIER':'1','GH_NO_EXTENSION_UPDATE_NOTIFIER':'1'}
 subprocess.run([str(mac/'probe'),str(work)],env=env,check=True,timeout=45)
print('SIGNED HARDENED DESKTOP FIXTURE PASSED; temporary bundle/home removed')
