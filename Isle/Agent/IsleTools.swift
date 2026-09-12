//
//  IsleTools.swift
//  Isle
//

import Foundation
import MCP
import Roboport

/// The shape every Isle tool provider already has: a set of MCP `Tool`
/// declarations and an async dispatch by name.
///
/// The declarations stay in MCP's vocabulary even though Isle no longer serves
/// MCP. That is deliberate: it is a perfectly good JSON-Schema tool description,
/// the SDK is still a dependency for the MCP *client*, and rewriting six
/// hand-written schema tables into a second format would risk transcription
/// bugs for no behavioural gain.
protocol IsleToolSurface: Sendable {
    static var tools: [MCP.Tool] { get }
    func call(name: String, arguments: [String: MCP.Value]?) async -> CallTool.Result
}

extension NotesTools: IsleToolSurface {}
extension MusicTools: IsleToolSurface {}
extension BrowserTools: IsleToolSurface {}

extension IsleToolSurface {
    /// This provider's tools, wrapped for the agent. Dispatch goes straight to
    /// `call` in-process — no server, no socket, no handshake.
    func agentTools() -> [any Roboport.Tool] {
        Self.tools.map { declaration in
            MCPBridge.tool(declaration) { arguments in
                let result = await call(name: declaration.name, arguments: arguments)
                return (result.content, result.isError)
            }
        }
    }
}

/// Collects the enabled providers into the agent's tool set.
///
/// Each provider is optional: `AppDelegate` builds only the ones whose
/// preference is on and whose system permission was granted, so a nil provider
/// simply contributes no tools.
enum IsleToolSet {
    struct Providers {
        var reminders: ReminderTools?
        var calendar: CalendarTools?
        var notes: NotesTools?
        var music: MusicTools?
        var mail: MailTools?
        var browser: BrowserTools?
    }

    static func tools(from providers: Providers) -> [any Roboport.Tool] {
        var tools: [any Roboport.Tool] = []
        if let value = providers.reminders { tools += value.agentTools() }
        if let value = providers.calendar { tools += value.agentTools() }
        if let value = providers.notes { tools += value.agentTools() }
        if let value = providers.music { tools += value.agentTools() }
        if let value = providers.mail { tools += value.agentTools() }
        if let value = providers.browser { tools += value.agentTools() }
        return tools
    }
}
