import MCP
import Robo

protocol PersonalToolSurface: Sendable {
    static var tools: [MCP.Tool] { get }
    func call(name: String, arguments: [String: MCP.Value]?) async -> CallTool.Result
}

extension ReminderTools: PersonalToolSurface {}
extension CalendarTools: PersonalToolSurface {}
extension MailTools: PersonalToolSurface {}
extension MapTools: PersonalToolSurface {}

extension PersonalToolSurface {
    func agentTools(allowing allowedNames: Set<String>? = nil) -> [any Robo.Tool] {
        Self.tools.compactMap { declaration in
            guard allowedNames?.contains(declaration.name) ?? true else { return nil }
            return MCPBridge.tool(declaration) { arguments in
                let result = await call(name: declaration.name, arguments: arguments)
                return (result.content, result.isError)
            }
        }
    }
}
