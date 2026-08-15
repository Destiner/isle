import Foundation

/// The default tool bundle: a shell and a web search, and nothing else.
///
/// Deliberately not a coding harness. There are no read/write/edit file tools —
/// a desktop assistant's filesystem work is occasional and `bash` covers it,
/// while a dedicated file-editing surface only invites the model to treat the
/// scratch directory as a project.
public enum Harness {
    /// Tool-use guidance only. The caller supplies the assistant's persona and
    /// voice separately, so this stays additive to any system prompt.
    public static let toolGuidance = """
        Available tools:
        - bash: run a shell command on the user's Mac
        - web_search: search the web

        Guidelines:
        - Reach for a purpose-built tool over bash when one fits; use bash for \
        anything else that needs the machine.
        - Use web_search when the answer depends on current or external \
        information, and say what you found rather than just linking it.
        - Prefer one well-aimed tool call over several speculative ones.
        - Tool output is for you, not the user: read it, then answer in your own \
        words. Never paste raw output unless the user asked to see it.
        - If a tool fails, say what failed and what you tried; do not silently \
        retry the same thing.
        """

    public static func tools() -> [any Tool] {
        [BashTool(), WebSearchTool()]
    }

    public static func provider() -> any ToolProvider {
        StaticToolProvider(tools())
    }
}
