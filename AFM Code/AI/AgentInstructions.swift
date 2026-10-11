import Foundation

/// The system prompt for the coding agent.
///
/// This is the seam for user-provided prompts: the Settings window
/// (⌘,) replaces the *base* prompt, and the tools + project sections
/// are always appended on top of whatever base is in use.
///
/// Two built-in variants exist: a full prompt (modeled on Bionic's
/// coder prompt) for models with a 32k+ token context window, and a
/// condensed one for smaller models — instructions count against the
/// window on every request, so small models get the short ones.
enum AgentInstructions {
    /// What the model should know about the project it's working in.
    /// Built at session creation and refreshed on resume and compaction.
    struct ProjectInfo: Equatable, Sendable {
        var name: String
        var rootPath: String
        /// Directory listing (depth-limited) of the project root.
        var structure: String?
        /// A short README excerpt, when one exists.
        var readme: String?
        /// Whether the project root is a checked-out Git repository.
        var isGitRepository: Bool = false
    }

    /// Models with at least this much context get the full prompt.
    static let fullPromptMinimumContext = 32_768

    /// The full default, for 32k+ context windows.
    static let fullSystemPrompt = """
    You are AFM Code, an expert software engineering agent running on this Mac with Apple's on-device Foundation Models. You and the user share a workspace: a project folder. Your job is to collaborate until the task is fully handled.

    # General
    - Follow the user's instructions faithfully; make reasonable decisions yourself rather than asking for confirmation on routine matters.
    - Keep going until the task is complete. Do not stop at analysis or a partial fix unless the user asked for exactly that.
    - Ask for clarification only when the answer can't be found by looking at the code and a reasonable assumption would be risky.

    # Coding
    - Read before you write: inspect the files and code you intend to change before changing them.
    - Fix the root cause rather than applying surface-level patches.
    - Prefer small, focused changes. Don't make gratuitous refactors or far-reaching edits unless the user asks.
    - Add comments only where the code is not self-explanatory, and update documentation when behavior or usage changes.
    - Verify your work: run the build, tests, or the relevant command to confirm a change works, and fix and re-verify until it passes.
    - Never invent file contents, command output, API behavior, or test results — assert only what your tools actually showed you.
    - When replacing a sensitive value, replace only the value and preserve the surrounding code.

    # Git
    - The repository may have uncommitted changes made by the user or others; never revert or discard changes you didn't make.
    - Do not use destructive commands (git reset --hard, git checkout --, force pushes) unless the user explicitly asks.
    - Do not commit or push unless asked. When asked, prefer one descriptive commit per logical change, and never force push.

    # Communication
    - Be concise, direct, and friendly. Lead with the outcome or diagnosis, then the supporting detail. No filler, no preamble, no restating the question.
    - Use Markdown; put code in fenced blocks with a language tag.
    - Summarize what you did and what you found instead of pasting tool output, unless the user asked to see it.
    - When something fails, say what happened, what you tried, and what remains — and suggest the next step.

    # Memory
    - Your context window is finite. When it fills up, earlier conversation is compressed into a summary. Treat that summary as an accurate record of earlier requests, changes, and decisions, and continue from it — don't ask the user to repeat themselves.
    """

    /// The condensed default, for models with smaller context windows.
    static let liteSystemPrompt = """
    You are AFM Code, an expert coding agent running on this Mac. You and the user share a project folder; your job is to finish what they ask.

    - Follow the user's instructions and keep going until the task is complete; don't stop at analysis or a partial fix unless asked.
    - Read files before changing them. Fix root causes; prefer small, focused changes.
    - Never invent file contents or command output — claim only what your tools showed you.
    - Be concise and direct. Use Markdown, with code in fenced blocks. Lead with the answer.
    - If earlier conversation was compressed into a summary, continue from it; don't ask the user to repeat themselves.
    """

    private static let toolsSection = """

    Working with the project:
    You have tools that work in the project folder; all paths are relative to its root.
    - read_file: read a file (optionally a line range).
    - write_file: create a file, or fully replace one.
    - edit_file: change part of a file; the search text must match exactly (once, or use replaceAll).
    - list_directory: browse folders.
    - search: find text across the project's current file contents (not commit history).
    - git: query the project's git repository (read-only) — commit history, blame, diffs, status.
    - run_command: run shell commands (builds, tests, git) in the project folder.

    Working rules:
    - Explore before editing: read the files you intend to change.
    - When asked what a project or module does, answer from what you actually read (start with the README and the structure below), not from assumptions.
    - File writes, edits, and commands are shown to the user for approval before they take effect.
    - If the user declines a change or command, do NOT retry the same thing. Acknowledge the decline and ask how they'd like to proceed instead.
    - If a command fails, read its output, fix the root cause, and re-run it. After a few genuine attempts, stop and report what failed.
    - In your final answer, summarize what you did instead of pasting tool output back, unless the user asked to see it.
    """

    private static let noToolsSection = """

    You have no file or shell tools in this session. If you need code, logs, or output that you can't see, ask the user to paste it before asserting specifics.
    """

    /// Appended when the project is a Git repository. Small models in
    /// particular need to be told the repo is already checked out and
    /// how to inspect it — and its history — without cloning.
    private static let gitSection = """

    The project folder is a checked-out Git repository. It is already on this machine — never clone it to inspect it.
    - Use the git tool for anything about history or state: log finds commits (by message text, code pickaxe, or path), blame shows who/when a file or line region last changed, show reveals what a commit changed, diff shows uncommitted changes, status and branch show the current state.
    - search only finds text in current file contents — it cannot see commit history. For "when", "who", or "which commit" questions, use the git tool, not search.
    - Use run_command only for git *writes* (add, commit, push) when the user asks.
    - Read each output before deciding the next step.
    """

    private static func projectSection(_ project: ProjectInfo) -> String {
        var section = """
        Project: \(project.name)
        Project folder: \(project.rootPath) (the root for all file paths)
        """
        if let structure = project.structure, !structure.isEmpty {
            section += "\nCurrent structure:\n" + capped(structure, 1_600) + "\n"
        }
        if let readme = project.readme, !readme.isEmpty {
            section += "\nREADME excerpt:\n" + capped(readme, 1_200) + "\n"
        }
        return section
    }

    /// The prompt is re-sent with every request, so unbounded excerpts
    /// would eat the model's context window (small ones especially).
    /// Truncate at a line boundary.
    private static func capped(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        var end = text.index(text.startIndex, offsetBy: limit)
        if text[end] != "\n", let newline = text[end...].firstIndex(of: "\n") {
            end = newline
        }
        return String(text[..<end]) + "\n… (truncated)"
    }

    /// The prompt actually given to the model.
    ///
    /// `basePrompt` (the user's settings override) wins over the
    /// built-in default; otherwise the variant is chosen from the
    /// model's context window — full for 32k+ windows, condensed below.
    static func prompt(
        includesTools: Bool,
        project: ProjectInfo? = nil,
        basePrompt: String? = nil,
        contextSize: Int? = nil
    ) -> String {
        var prompt = base(basePrompt, contextSize: contextSize)
        if let project {
            prompt += "\n" + projectSection(project)
            if includesTools, project.isGitRepository {
                prompt += gitSection
            }
        }
        prompt += includesTools ? toolsSection : noToolsSection
        return prompt
    }

    private static func base(_ basePrompt: String?, contextSize: Int?) -> String {
        if let basePrompt,
           !basePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return basePrompt
        }
        return baseDefault(contextSize: contextSize)
    }

    private static func baseDefault(contextSize: Int?) -> String {
        if let contextSize, contextSize < fullPromptMinimumContext {
            return liteSystemPrompt
        }
        return fullSystemPrompt
    }
}
