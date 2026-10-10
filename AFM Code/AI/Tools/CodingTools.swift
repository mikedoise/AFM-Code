import FoundationModels

/// The coding agent's tool set, built per session.
///
/// Each tool captures the session's `ToolContext` (folder, approvals,
/// step bookkeeping). Built once when the session is created; the
/// framework runs the tool-call loop, these do the work.
struct CodingTools {
    let tools: [any Tool]

    init(context: ToolContext) {
        tools = [
            ReadFileTool(context: context),
            WriteFileTool(context: context),
            EditFileTool(context: context),
            ListDirectoryTool(context: context),
            SearchTool(context: context),
            RunCommandTool(context: context)
        ]
    }
}
