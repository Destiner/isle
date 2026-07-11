import Foundation

nonisolated struct NoteFolderDTO: Codable, Sendable {
    let id: String
    let name: String
    let parentID: String?
    let parentName: String?
}

nonisolated struct NoteDTO: Codable, Sendable {
    let id: String
    let title: String
    let folderID: String
    let folder: String
    let creationDate: String
    let modificationDate: String
    let passwordProtected: Bool
    let shared: Bool
    let body: String?
}

nonisolated enum NotesError: LocalizedError {
    case notPermitted, notFound(String), script(String)
    var errorDescription: String? {
        switch self {
        case .notPermitted: "Isle hasn't been granted Automation access to Notes. Grant it in System Settings › Privacy & Security › Automation, then relaunch Isle."
        case .notFound(let id): "No note or folder found with id \(id)."
        case .script(let message): "Notes scripting failed: \(message)"
        }
    }
}

actor NotesService {
    private let provider = AppleNotesProvider()
    func folders() async throws -> [NoteFolderDTO] { try await provider.folders() }
    func list(folderID: String?, limit: Int) async throws -> [NoteDTO] { try await provider.list(folderID: folderID, limit: limit) }
    func search(query: String, folderID: String?, limit: Int) async throws -> [NoteDTO] { try await provider.search(query: query, folderID: folderID, limit: limit) }
    func get(id: String) async throws -> NoteDTO { try await provider.get(id: id) }
    func create(title: String, body: String, folderID: String?) async throws -> NoteDTO { try await provider.create(title: title, body: body, folderID: folderID) }
    func edit(id: String, title: String?, body: String?) async throws -> NoteDTO { try await provider.edit(id: id, title: title, body: body) }
    func append(id: String, text: String) async throws -> NoteDTO { try await provider.append(id: id, text: text) }
}

nonisolated final class AppleNotesProvider: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DestinerLabs.Isle.notes-applescript")
    private static let unit = "\u{1F}"
    private static let record = "\u{1E}"

    func folders() async throws -> [NoteFolderDTO] {
        let raw = try await run("""
        set US to (character id 31)
        set RS to (character id 30)
        tell application "Notes"
            set out to ""
            repeat with f in folders
                set p to container of f
                set out to out & ((id of f) as string) & US & ((name of f) as string) & US & ((id of p) as string) & US & ((name of p) as string) & RS
            end repeat
            return out
        end tell
        """)
        return raw.split(separator: Character(Self.record)).compactMap { row in
            let fields = row.components(separatedBy: Self.unit)
            guard fields.count == 4 else { return nil }
            return NoteFolderDTO(id: fields[0], name: fields[1], parentID: fields[2].isEmpty ? nil : fields[2], parentName: fields[3].isEmpty ? nil : fields[3])
        }
    }

    func list(folderID: String?, limit: Int) async throws -> [NoteDTO] {
        try await rows(Self.notesExpr(folderID), query: nil, limit: limit)
    }

    func search(query: String, folderID: String?, limit: Int) async throws -> [NoteDTO] {
        try await rows(Self.notesExpr(folderID), query: query, limit: limit)
    }

    func get(id: String) async throws -> NoteDTO {
        let raw = try await run("""
        \(Self.prelude)
        tell application "Notes"
            set n to note id \(Self.literal(id))
            return my rowFor(n, true)
        end tell
        """)
        guard let note = Self.parseRow(raw, includeBody: true) else { throw NotesError.notFound(id) }
        return note
    }

    func create(title: String, body: String, folderID: String?) async throws -> NoteDTO {
        let folder = folderID.map { "folder id \(Self.literal($0))" } ?? "default folder of default account"
        let raw = try await run("""
        \(Self.prelude)
        tell application "Notes"
            set n to make new note at \(folder) with properties {name:\(Self.literal(title)), body:\(Self.literal(Self.html(title: title, body: body)))}
            return my rowFor(n, true)
        end tell
        """)
        guard let note = Self.parseRow(raw, includeBody: true) else { throw NotesError.script("created note couldn't be read") }
        return note
    }

    func edit(id: String, title: String?, body: String?) async throws -> NoteDTO {
        var mutations: [String] = []
        if let title { mutations.append("set name of n to \(Self.literal(title))") }
        if let body { mutations.append("set body of n to \(Self.literal(Self.html(title: title ?? "", body: body)))") }
        let raw = try await run("""
        \(Self.prelude)
        tell application "Notes"
            set n to note id \(Self.literal(id))
            \(mutations.joined(separator: "\n            "))
            return my rowFor(n, true)
        end tell
        """)
        guard let note = Self.parseRow(raw, includeBody: true) else { throw NotesError.notFound(id) }
        return note
    }

    func append(id: String, text: String) async throws -> NoteDTO {
        let raw = try await run("""
        \(Self.prelude)
        tell application "Notes"
            set n to note id \(Self.literal(id))
            set body of n to ((body of n) & \(Self.literal(Self.htmlFragment(text))))
            return my rowFor(n, true)
        end tell
        """)
        guard let note = Self.parseRow(raw, includeBody: true) else { throw NotesError.notFound(id) }
        return note
    }

    private func rows(_ expression: String, query: String?, limit: Int) async throws -> [NoteDTO] {
        let matching = query.map { """
            set ns to {}
            repeat with n in allNotes
                try
                    if (plaintext of n as text) contains \(Self.literal($0)) then set end of ns to n
                end try
            end repeat
            """ } ?? "set ns to allNotes"
        let raw = try await run("""
        \(Self.prelude)
        tell application "Notes"
            set allNotes to \(expression)
            \(matching)
            set lim to \(max(0, min(limit, 100)))
            if (count of ns) < lim then set lim to count of ns
            set out to ""
            repeat with i from 1 to lim
                set out to out & my rowFor(item i of ns, false) & RS
            end repeat
            return out
        end tell
        """)
        return raw.split(separator: Character(Self.record)).compactMap { Self.parseRow(String($0), includeBody: false) }
    }

    private static func notesExpr(_ folderID: String?) -> String {
        folderID.map { "every note of folder id \(literal($0))" } ?? "every note"
    }

    private static let prelude = """
    set US to (character id 31)
    set RS to (character id 30)
    on rowFor(n, includeBody)
        set f to container of n
        set out to ((id of n) as string) & US & ((name of n) as string) & US & ((id of f) as string) & US & ((name of f) as string) & US & ((creation date of n) as string) & US & ((modification date of n) as string) & US & ((password protected of n) as string) & US & ((shared of n) as string)
        if includeBody then set out to out & US & ((plaintext of n) as string)
        return out
    end rowFor
    """

    private func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let script = NSAppleScript(source: source) else { continuation.resume(throwing: NotesError.script("failed to compile")); return }
                var info: NSDictionary?
                let result = script.executeAndReturnError(&info)
                if let info { continuation.resume(throwing: Self.mapError(info)); return }
                continuation.resume(returning: result.stringValue ?? "")
            }
        }
    }

    private static func mapError(_ info: NSDictionary) -> NotesError {
        let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
        if code == -1743 || code == -10004 { return .notPermitted }
        if code == -1728 { return .notFound("") }
        return .script("\((info[NSAppleScript.errorMessage] as? String) ?? "unknown error") (\(code))")
    }

    static func parseRow(_ row: String, includeBody: Bool) -> NoteDTO? {
        let fields = row.components(separatedBy: unit)
        guard fields.count >= 8 else { return nil }
        return NoteDTO(id: fields[0], title: fields[1], folderID: fields[2], folder: fields[3], creationDate: fields[4], modificationDate: fields[5], passwordProtected: fields[6] == "true", shared: fields[7] == "true", body: includeBody ? fields.dropFirst(8).joined(separator: unit) : nil)
    }

    static func literal(_ value: String) -> String {
        value.components(separatedBy: "\n").map { "\"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: " & linefeed & ")
    }

    static func html(title: String, body: String) -> String { "<div>\(escape(title))</div>\(htmlFragment(body))" }
    static func htmlFragment(_ text: String) -> String { "<div>\(escape(text).replacingOccurrences(of: "\n", with: "<br>"))</div>" }
    private static func escape(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
}
