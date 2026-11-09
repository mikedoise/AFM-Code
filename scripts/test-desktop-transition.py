#!/usr/bin/env python3
"""Desktop transition against disposable legacy store/preferences only.
Does not open the user's AFM store, execute user commands or launch the GUI.
"""
from pathlib import Path
import os, subprocess, tempfile, plistlib
root=Path(__file__).resolve().parents[1]
models=['Project','ChatSession','Message','MlxModel','ModelDescriptor','MCPServer']
with tempfile.TemporaryDirectory(prefix='afm-desktop-transition-') as tmp:
    base=Path(tmp);old=base/'old';old.mkdir();home=base/'home';home.mkdir()
    support=home/'Library/Containers/app.techopolis.AFMCode/Data/Library/Application Support';support.mkdir(parents=True)
    prefs=home/'Library/Containers/app.techopolis.AFMCode/Data/Library/Preferences';prefs.mkdir(parents=True)
    (prefs/'app.techopolis.AFMCode.plist').write_bytes(plistlib.dumps({'settings.systemPrompt':'Keep prompt','coreAI.importedModels.v1':b'fixture-bookmarks','chatBubbleStyle':'fixture','not.owned':'do-not-import'}))
    for name in models:
        text=(root/f'AFM Code/Models/{name}.swift').read_text()
        lines=[l for l in text.splitlines() if not any(x in l for x in ['var desktopAccessVersion:', 'var sandboxCommandAllowlist:', 'var sandboxApprovalModeRaw:', 'var wasEnabledInSandbox:', 'self.desktopAccessVersion ='])]
        (old/f'{name}.swift').write_text('\n'.join(lines))
    stub=base/'Stub.swift';stub.write_text('import Foundation\nstruct ToolStep: Codable {}\nenum ApprovalMode: String { case ask, auto }\n')
    writer=base/'Writer.swift';writer.write_text('''import Foundation
import SwiftData
@main struct Writer { @MainActor static func main() throws {
 let schema=Schema([Project.self,ChatSession.self,Message.self,MlxModel.self,MCPServer.self])
 let c=try ModelContainer(for:schema,configurations:[ModelConfiguration(schema:schema,url:URL(fileURLWithPath:CommandLine.arguments[1]),cloudKitDatabase:.none)])
 let p=Project(name:"Keep project"); p.approvalMode = .auto; p.commandAllowlist=["legacy-command", "mcp__legacy__tool"]; p.bookmarkData=Data("keep-bookmark".utf8); c.mainContext.insert(p)
 let s=ChatSession.create(in:p,context:c.mainContext);s.title="Keep session";s.transcriptData=Data("keep-transcript".utf8)
 let m=Message(role:.user,content:"Keep message");m.imageData=Data([1,2,3]);m.session=s;c.mainContext.insert(m)
 let server=MCPServer(name:"Keep MCP",command:"/not-executed",environment:["FIXTURE":"keep"],isEnabled:true);c.mainContext.insert(server)
 c.mainContext.insert(MlxModel(repoID:"keep/model",maxContextTokens:8192));try c.mainContext.save()
 print("PASS wrote legacy store with automatic grants and enabled MCP")
}}
''')
    reader=base/'Reader.swift';reader.write_text('''import Foundation
import SwiftData
@main struct Reader { @MainActor static func main() async throws {
 let home=URL(fileURLWithPath:CommandLine.arguments[1]);let suite="afm.fixture."+UUID().uuidString;let defaults=UserDefaults(suiteName:suite)!;defer{defaults.removePersistentDomain(forName:suite)}
 let locations=try DesktopStorage.prepare(home:home,defaults:defaults)
 precondition(locations.reusesLegacyStore && locations.store.path.contains("Containers/app.techopolis.AFMCode"))
 precondition(defaults.string(forKey:"settings.systemPrompt")=="Keep prompt" && defaults.data(forKey:"coreAI.importedModels.v1")==Data("fixture-bookmarks".utf8))
 precondition(defaults.object(forKey:"not.owned")==nil)
 defaults.set("New choice",forKey:"settings.systemPrompt");_ = try DesktopStorage.prepare(home:home,defaults:defaults);precondition(defaults.string(forKey:"settings.systemPrompt")=="New choice")
 let schema=ModelContainerProvider.schema;let config=ModelConfiguration(schema:schema,url:locations.store,cloudKitDatabase:.none)
 let container=try ModelContainer(for:schema,configurations:[config]);let context=container.mainContext
 let p=try context.fetch(FetchDescriptor<Project>()).first!;let server=try context.fetch(FetchDescriptor<MCPServer>()).first!
 precondition(p.desktopAccessVersion==nil && server.desktopAccessVersion==nil)
 let gate=ToolApprovalService(project:p)
 precondition(!gate.commandIsAllowed("legacy-command"))
 let pending=Task{await gate.wait(for:UUID(),command:"legacy-command")}
 for _ in 0..<200{if !gate.pendingStepIDs.isEmpty{break};try await Task.sleep(for:.milliseconds(5))}
 precondition(!gate.pendingStepIDs.isEmpty,"Unmigrated auto grant was reused");gate.reset();_ = await pending.value
 try DesktopApprovalMigration.apply(to:context)
 precondition(p.desktopAccessVersion==1 && p.approvalMode == .ask && p.commandAllowlist==[])
 precondition(p.sandboxCommandAllowlist==["legacy-command","mcp__legacy__tool"] && p.sandboxApprovalModeRaw=="auto")
 precondition(server.desktopAccessVersion==1 && !server.isEnabled && server.wasEnabledInSandbox==true)
 precondition(server.command=="/not-executed" && server.environment["FIXTURE"]=="keep")
 precondition(p.bookmarkData==Data("keep-bookmark".utf8))
 let session=try context.fetch(FetchDescriptor<ChatSession>()).first!;precondition(session.title=="Keep session" && session.transcriptData==Data("keep-transcript".utf8))
 let msg=try context.fetch(FetchDescriptor<Message>()).first!;precondition(msg.content=="Keep message" && msg.imageData==Data([1,2,3]))
 let mlxCount=try context.fetchCount(FetchDescriptor<MlxModel>());precondition(mlxCount==1)
 p.commandAllowlist=["command:fresh-desktop-command"];try context.save();try DesktopApprovalMigration.apply(to:context)
 precondition(gate.commandIsAllowed("fresh-desktop-command") && !gate.commandIsAllowed("legacy-command"))
 p.desktopAccessVersion=99;try context.save()
 do{try DesktopApprovalMigration.apply(to:context);preconditionFailure("Future format modified")}catch{}
 precondition(p.desktopAccessVersion==99 && p.commandAllowlist==["command:fresh-desktop-command"])
 p.desktopAccessVersion=1;try context.save()
 let ordinaryFolder=home.appendingPathComponent("ordinary-workspace");try FileManager.default.createDirectory(at:ordinaryFolder,withIntermediateDirectories:true)
 try Data("ordinary-access".utf8).write(to:ordinaryFolder.appendingPathComponent("sample.txt"))
 let ordinary=Project(name:"Ordinary bookmark fixture");ordinary.bookmarkData=try ordinaryFolder.bookmarkData(options:[])
 let workspace=Workspace(project:ordinary);precondition(workspace.status == .active)
 let content=try workspace.withAccess{try String(contentsOf:$0.appendingPathComponent("sample.txt"),encoding:.utf8)}
 precondition(content=="ordinary-access" && workspace.acquireLease());workspace.releaseLease()
 print("PASS real ordinary bookmark resolves and desktop workspace access succeeds")
 let missingHome=home.appendingPathComponent("missing-store-case")
 let missingSupport=missingHome.appendingPathComponent("Library/Containers/app.techopolis.AFMCode/Data/Library/Application Support")
 try FileManager.default.createDirectory(at:missingSupport,withIntermediateDirectories:true)
 try Data("wal-fixture".utf8).write(to:missingSupport.appendingPathComponent("default.store-wal"))
 do{_ = try DesktopStorage.prepare(home:missingHome,defaults:defaults);preconditionFailure("Opened replacement for missing legacy store")}catch{}
 precondition(!FileManager.default.fileExists(atPath:missingHome.appendingPathComponent("Library/Application Support/AFM Code/default.store").path))
 let badPreferences=home.appendingPathComponent("bad-preferences.plist");try Data("not a plist".utf8).write(to:badPreferences)
 let failedSuite="afm.failed."+UUID().uuidString;let failedDefaults=UserDefaults(suiteName:failedSuite)!;defer{failedDefaults.removePersistentDomain(forName:failedSuite)}
 do{try DesktopStorage.importPreferences(from:badPreferences,defaults:failedDefaults);preconditionFailure("Corrupt preferences accepted")}catch{}
 precondition(!failedDefaults.bool(forKey:"desktop.preferencesImported.v1"))
 print("PASS missing legacy store and corrupt preferences fail closed without replacement")
 print("PASS store/preferences preserved; old auto grants blocked and archived; MCP paused; fresh grants survive repeat migration; future versions fail closed")
}}
''')
    common=['xcrun','swiftc','-parse-as-library','-swift-version','6','-target','arm64-apple-macos27.0']
    subprocess.run(common+[str(old/f'{n}.swift') for n in models]+[str(stub),str(writer),'-o',str(base/'write')],check=True)
    # Use real approval service rather than the stub ApprovalMode for the reader.
    readstub=base/'ReadStub.swift';readstub.write_text('import Foundation\nstruct ToolStep: Codable {}\n')
    source=['App/DesktopStorage.swift','App/DesktopApprovalMigration.swift','App/ModelContainerProvider.swift','AI/ToolApprovalService.swift','AI/Workspace.swift']
    subprocess.run(common+[str(root/f'AFM Code/Models/{n}.swift') for n in models]+[str(root/'AFM Code'/n) for n in source]+[str(readstub),str(reader),'-o',str(base/'read')],check=True)
    reopen=base/'Reopen.swift';reopen.write_text('''import Foundation
import SwiftData
@main struct Reopen { @MainActor static func main() throws {
 let schema=ModelContainerProvider.schema
 let container=try ModelContainer(for:schema,configurations:[ModelConfiguration(schema:schema,url:URL(fileURLWithPath:CommandLine.arguments[1]),cloudKitDatabase:.none)])
 let context=container.mainContext;try DesktopApprovalMigration.apply(to:context)
 let p=try context.fetch(FetchDescriptor<Project>()).first{$0.name=="Keep project"}!
 let server=try context.fetch(FetchDescriptor<MCPServer>()).first!
 precondition(p.desktopAccessVersion==1 && p.approvalMode == .ask && p.commandAllowlist==["command:fresh-desktop-command"])
 precondition(p.sandboxCommandAllowlist==["legacy-command","mcp__legacy__tool"] && p.sandboxApprovalModeRaw=="auto")
 precondition(server.desktopAccessVersion==1 && !server.isEnabled && server.wasEnabledInSandbox==true)
 precondition(p.bookmarkData==Data("keep-bookmark".utf8))
 let count=try context.fetchCount(FetchDescriptor<Message>());precondition(count==1)
 print("PASS separate-process reopen preserves data, archived old grants, fresh desktop grants and paused MCP")
}}
''')
    subprocess.run(common+[str(root/f'AFM Code/Models/{n}.swift') for n in models]+[str(root/'AFM Code'/n) for n in source]+[str(readstub),str(reopen),'-o',str(base/'reopen')],check=True)
    env={**os.environ,'HOME':str(home),'CFFIXED_USER_HOME':str(home),'ZDOTDIR':str(home)}
    subprocess.run([str(base/'write'),str(support/'default.store')],env=env,check=True)
    subprocess.run([str(base/'read'),str(home)],env=env,check=True)
    subprocess.run([str(base/'reopen'),str(support/'default.store')],env=env,check=True)
app=(root/'AFM Code/App/AFMCodeApp.swift').read_text()
assert app.index('guard others.isEmpty') < app.index('ModelContainerProvider.containerResult.get()') < app.index('State(initialValue: ChatController())')
assert 'desktopAccessVersion == 1' in (root/'AFM Code/AI/MCP/MCPHostManager.swift').read_text()
print('PASS source guards: no concurrent legacy store startup, preference import precedes managers, live MCP authority guard')
