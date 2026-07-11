import Foundation
import MCP

nonisolated struct MusicTools: Sendable {
    let service: MusicService
    static let toolNames: Set<String> = Set(tools.map(\.name))
    static let tools: [Tool] = [
        Tool(name: "get_now_playing", description: "Get Music's current playback state and track.", inputSchema: ["type":"object", "properties":[:]]),
        Tool(name: "music_playback", description: "Control Music playback.", inputSchema: ["type":"object", "properties":["action":["type":"string", "enum":["play","pause","toggle","next","previous","stop"]]], "required":["action"]]),
        Tool(name: "search_music_library", description: "Search the user's Music library by song, artist, or album.", inputSchema: ["type":"object", "properties":["query":["type":"string"],"limit":["type":"integer"]], "required":["query"]]),
        Tool(name: "play_music_item", description: "Play a track or playlist returned by Music tools.", inputSchema: ["type":"object", "properties":["track_id":["type":"string"],"playlist_id":["type":"string"]]]),
        Tool(name: "list_music_playlists", description: "List user Music playlists.", inputSchema: ["type":"object", "properties":[:]]),
    ]
    func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        do { switch name {
        case "get_now_playing": return Self.json(try await service.nowPlaying())
        case "music_playback": guard let a=arguments?["action"]?.stringValue else{return Self.error("Missing required argument: action")}; return Self.json(try await service.control(a))
        case "search_music_library": guard let q=arguments?["query"]?.stringValue else{return Self.error("Missing required argument: query")}; return Self.json(try await service.search(query:q, limit:arguments?["limit"]?.intValue ?? 20))
        case "play_music_item": return Self.json(try await service.play(trackID:arguments?["track_id"]?.stringValue, playlistID:arguments?["playlist_id"]?.stringValue))
        case "list_music_playlists": return Self.json(try await service.playlists())
        default: return Self.error("Unknown tool: \(name)")
        }} catch { return Self.error((error as? LocalizedError)?.errorDescription ?? "\(error)") }
    }
    private static func error(_ s:String)->CallTool.Result { .init(content:[.text(text:s,annotations:nil,_meta:nil)],isError:true) }
    private static func json<T:Encodable>(_ v:T)->CallTool.Result { let e=JSONEncoder(); e.outputFormatting=[.prettyPrinted,.sortedKeys]; guard let d=try? e.encode(v),let s=String(data:d,encoding:.utf8) else{return error("Failed to encode result.")}; return .init(content:[.text(text:s,annotations:nil,_meta:nil)]) }
}
