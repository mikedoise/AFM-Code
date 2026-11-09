#!/usr/bin/env python3
"""Open a temporary old-schema store with the production schema and verify preservation.
Never opens or edits AFM Code's real application-support database.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
model_names = ['Project','ChatSession','Message','MlxModel','ModelDescriptor']
with tempfile.TemporaryDirectory(prefix='afm-schema-regression-') as temporary:
    temp = Path(temporary)
    old = temp/'old'; old.mkdir()
    for name in model_names:
        data = subprocess.check_output(['git','show',f'HEAD:AFM Code/Models/{name}.swift'], cwd=root)
        (old/f'{name}.swift').write_bytes(data)
    stub = temp/'Stubs.swift'
    stub.write_text('import Foundation\nstruct ToolStep: Codable {}\nenum ApprovalMode: String { case ask, auto }\n')
    writer = temp/'WriteOld.swift'
    writer.write_text('''import Foundation
import SwiftData
@main struct WriteOld {
 @MainActor static func main() throws {
  let schema = Schema([Project.self, ChatSession.self, Message.self, MlxModel.self])
  let config = ModelConfiguration(schema: schema, url: URL(fileURLWithPath: CommandLine.arguments[1]), cloudKitDatabase: .none)
  let container = try ModelContainer(for: schema, configurations: [config])
  let context = container.mainContext
  let project = Project(name: "Preserve Project")
  project.bookmarkData = Data("fixture bookmark".utf8)
  project.commandAllowlist = ["git status"]
  context.insert(project)
  let session = ChatSession.create(in: project, context: context)
  session.title = "Preserve Session"
  session.transcriptData = Data("fixture transcript".utf8)
  let message = Message(role: .user, content: "Preserve message and attachment")
  message.imageData = Data([1, 2, 3]); message.session = session
  context.insert(message); session.messages = [message]
  context.insert(MlxModel(repoID: "fixture/model", maxContextTokens: 8192))
  try context.save()
  print("PASS wrote legacy four-entity disk fixture")
 }
}
''')
    reader = temp/'ReadNew.swift'
    reader.write_text('''import Foundation
import SwiftData
@main struct ReadNew {
 @MainActor static func main() throws {
  let schema = ModelContainerProvider.schema
  precondition(Set(schema.entities.map(\\.name)).contains("MCPServer"))
  let config = ModelConfiguration(schema: schema, url: URL(fileURLWithPath: CommandLine.arguments[1]), cloudKitDatabase: .none)
  let container = try ModelContainer(for: schema, configurations: [config])
  let context = container.mainContext
  let project = try context.fetch(FetchDescriptor<Project>()).first!
  precondition(project.name == "Preserve Project" && project.commandAllowlist == ["git status"])
  precondition(project.bookmarkData == Data("fixture bookmark".utf8))
  let session = try context.fetch(FetchDescriptor<ChatSession>()).first!
  precondition(session.title == "Preserve Session" && session.project?.id == project.id)
  precondition(session.transcriptData == Data("fixture transcript".utf8))
  precondition(project.coreAIModelID == nil && session.coreAIModelID == nil)
  let message = try context.fetch(FetchDescriptor<Message>()).first!
  precondition(message.content == "Preserve message and attachment" && message.imageData == Data([1, 2, 3]))
  precondition(session.messageList.count == 1)
  let mlxCount = try context.fetchCount(FetchDescriptor<MlxModel>())
  precondition(mlxCount == 1)
  print("PASS migrated projects, sessions, relationships, messages, attachments, bookmarks, transcript, allowlist and MLX model")
  if try context.fetchCount(FetchDescriptor<MCPServer>()) == 0 {
   context.insert(MCPServer(name: "Fixture MCP", command: "/not-executed", isEnabled: false))
   try context.save()
  }
  let serverCount = try context.fetchCount(FetchDescriptor<MCPServer>())
  precondition(serverCount == 1)
  let history = try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
  precondition(!history.isEmpty)
  print("PASS MCPServer fetch, save and persistent history on migrated store")
 }
}
''')
    common=['xcrun','swiftc','-parse-as-library','-swift-version','5','-target','arm64-apple-macos27.0']
    subprocess.run(common+[str(p) for p in old.glob('*.swift')]+[str(stub),str(writer),'-o',str(temp/'write')], check=True)
    subprocess.run(common+[str(root/f'AFM Code/Models/{name}.swift') for name in model_names+['MCPServer']]+[str(root/'AFM Code/App/ModelContainerProvider.swift'),str(root/'AFM Code/App/DesktopStorage.swift'),str(root/'AFM Code/App/DesktopApprovalMigration.swift'),str(stub),str(reader),'-o',str(temp/'read')], check=True)
    store=str(temp/'fixture.store')
    subprocess.run([str(temp/'write'),store], check=True)
    subprocess.run([str(temp/'read'),store], check=True)
    subprocess.run([str(temp/'read'),store], check=True)
    print('PASS reopening migrated store preserves MCP data')
app=(root/'AFM Code/App/AFMCodeApp.swift').read_text()
assert app.count('.modelContainer(ModelContainerProvider.container)') == 2
print('PASS main and Settings scenes use the same container')
