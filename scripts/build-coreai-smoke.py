#!/usr/bin/env python3
"""Link the native smoke against the exact adapter objects from an AFM Code Xcode build.
Usage: python3 scripts/build-coreai-smoke.py /path/to/DerivedData/AFM_Code-... [/tmp/output] [source.swift ...]
"""
import pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[1]
derived = pathlib.Path(sys.argv[1])
products = derived / 'Build/Products/Debug'
output = sys.argv[2] if len(sys.argv) > 2 else '/tmp/afm-coreai-native-smoke'
objects = ['CoreAILanguageModels','CoreAIShared','CXGrammar','XGrammar','Tokenizers','Hub','Jinja','OrderedCollections','InternalCollectionsUtilities','yyjson','HuggingFace','Crypto','EventSource']
sources = sys.argv[3:] or [str(root/'scripts/CoreAINativeSmoke.swift')]
cmd = ['xcrun','swiftc','-parse-as-library','-target','arm64-apple-macos27.0','-I',str(products),'-F',str(products/'PackageFrameworks')] + sources
cmd += ['-I', str(root/'Packages/coreai-models-afm/Sources/lib/CXGrammar/include')]
cmd += ['-I', str(derived/'SourcePackages/checkouts/xgrammar/include')]
for module in ['yyjson']:
    maps = list((derived/'Build/Intermediates.noindex').glob(f'GeneratedModuleMaps/{module}.modulemap'))
    for path in maps: cmd += ['-Xcc',f'-fmodule-map-file={path}']
cmd += [str(products/(name+'.o')) for name in objects]
sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'], text=True).strip()
cmd += ['-sdk', sdk, '-F', sdk+'/System/Library/SubFrameworks', '-lc++','-o',output]
subprocess.run(cmd, check=True)
print(output)
