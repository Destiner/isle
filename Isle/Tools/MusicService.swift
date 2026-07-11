import Foundation

nonisolated struct MusicTrackDTO: Codable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
}

nonisolated struct MusicPlaybackDTO: Codable, Sendable {
    let state: String
    let position: Double
    let volume: Int
    let track: MusicTrackDTO?
}

nonisolated struct MusicPlaylistDTO: Codable, Sendable {
    let id: String
    let name: String
    let trackCount: Int
}

nonisolated enum MusicError: LocalizedError {
    case notPermitted, notFound, script(String)
    var errorDescription: String? {
        switch self {
        case .notPermitted: "Isle hasn't been granted Automation access to Music."
        case .notFound: "No matching Music item was found."
        case .script(let message): "Music scripting failed: \(message)"
        }
    }
}

actor MusicService {
    private let provider = AppleMusicProvider()
    func nowPlaying() async throws -> MusicPlaybackDTO { try await provider.nowPlaying() }
    func control(_ action: String) async throws -> MusicPlaybackDTO { try await provider.control(action) }
    func search(query: String, limit: Int) async throws -> [MusicTrackDTO] { try await provider.search(query: query, limit: limit) }
    func play(trackID: String?, playlistID: String?) async throws -> MusicPlaybackDTO { try await provider.play(trackID: trackID, playlistID: playlistID) }
    func playlists() async throws -> [MusicPlaylistDTO] { try await provider.playlists() }
}

nonisolated final class AppleMusicProvider: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DestinerLabs.Isle.music-applescript")
    private static let unit = "\u{1F}"
    private static let record = "\u{1E}"

    func nowPlaying() async throws -> MusicPlaybackDTO {
        let raw = try await run("""
        set US to (character id 31)
        tell application "Music"
            set out to (player state as string) & US & (player position as string) & US & (sound volume as string)
            if player state is stopped then return out
            set t to current track
            return out & US & (persistent ID of t) & US & (name of t) & US & (artist of t) & US & (album of t) & US & (duration of t as string)
        end tell
        """)
        return try Self.parsePlayback(raw)
    }

    func control(_ action: String) async throws -> MusicPlaybackDTO {
        let commands = ["play": "play", "pause": "pause", "toggle": "playpause", "next": "next track", "previous": "previous track", "stop": "stop"]
        guard let command = commands[action] else { throw MusicError.script("Unknown playback action: \(action)") }
        _ = try await run("tell application \"Music\" to \(command)")
        return try await nowPlaying()
    }

    func search(query: String, limit: Int) async throws -> [MusicTrackDTO] {
        let raw = try await run("""
        set US to (character id 31)
        set RS to (character id 30)
        tell application "Music"
            set xs to (every track of library playlist 1 whose name contains \(Self.literal(query)) or artist contains \(Self.literal(query)) or album contains \(Self.literal(query)))
            set lim to \(max(1, min(limit, 100)))
            if (count of xs) < lim then set lim to count of xs
            set out to ""
            repeat with i from 1 to lim
                set t to item i of xs
                set out to out & (persistent ID of t) & US & (name of t) & US & (artist of t) & US & (album of t) & US & (duration of t as string) & RS
            end repeat
            return out
        end tell
        """)
        return raw.split(separator: Character(Self.record)).compactMap { Self.parseTrack(String($0)) }
    }

    func play(trackID: String?, playlistID: String?) async throws -> MusicPlaybackDTO {
        if let trackID {
            _ = try await run("tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \(Self.literal(trackID)))")
        } else if let playlistID {
            _ = try await run("tell application \"Music\" to play (first playlist whose persistent ID is \(Self.literal(playlistID)))")
        } else { throw MusicError.notFound }
        return try await nowPlaying()
    }

    func playlists() async throws -> [MusicPlaylistDTO] {
        let raw = try await run("""
        set US to (character id 31)
        set RS to (character id 30)
        tell application "Music"
            set out to ""
            repeat with p in user playlists
                set out to out & (persistent ID of p) & US & (name of p) & US & ((count of tracks of p) as string) & RS
            end repeat
            return out
        end tell
        """)
        return raw.split(separator: Character(Self.record)).compactMap { row in
            let fields = row.components(separatedBy: Self.unit)
            guard fields.count == 3, let count = Int(fields[2]) else { return nil }
            return MusicPlaylistDTO(id: fields[0], name: fields[1], trackCount: count)
        }
    }

    private func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let script = NSAppleScript(source: source) else { continuation.resume(throwing: MusicError.script("failed to compile")); return }
                var info: NSDictionary?
                let result = script.executeAndReturnError(&info)
                if let info {
                    let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
                    if code == -1743 || code == -10004 { continuation.resume(throwing: MusicError.notPermitted) }
                    else if code == -1728 { continuation.resume(throwing: MusicError.notFound) }
                    else { continuation.resume(throwing: MusicError.script((info[NSAppleScript.errorMessage] as? String) ?? "unknown error")) }
                } else { continuation.resume(returning: result.stringValue ?? "") }
            }
        }
    }

    private static func parsePlayback(_ raw: String) throws -> MusicPlaybackDTO {
        let fields = raw.components(separatedBy: unit)
        guard fields.count >= 3, let position = Double(fields[1]), let volume = Int(fields[2]) else { throw MusicError.script("unexpected playback response") }
        guard fields.count == 8, let duration = Double(fields[7]) else { return MusicPlaybackDTO(state: fields[0], position: position, volume: volume, track: nil) }
        return MusicPlaybackDTO(state: fields[0], position: position, volume: volume, track: MusicTrackDTO(id: fields[3], title: fields[4], artist: fields[5], album: fields[6], duration: duration))
    }

    private static func parseTrack(_ row: String) -> MusicTrackDTO? {
        let fields = row.components(separatedBy: unit)
        guard fields.count == 5, let duration = Double(fields[4]) else { return nil }
        return MusicTrackDTO(id: fields[0], title: fields[1], artist: fields[2], album: fields[3], duration: duration)
    }

    static func literal(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
