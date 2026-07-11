import MCP
import Testing
@testable import Isle

struct NotesToolsTests {
    @Test func exposesExpectedToolNames() {
        #expect(NotesTools.toolNames == Set([
            "list_note_folders", "list_notes", "search_notes", "get_note",
            "create_note", "edit_note", "append_to_note",
        ]))
    }

    @Test func escapesAppleScriptStrings() {
        #expect(AppleNotesProvider.literal("say \"hi\"") == "\"say \\\"hi\\\"\"")
        #expect(AppleNotesProvider.literal("a\nb") == "\"a\" & linefeed & \"b\"")
    }
}
