import Roboport

nonisolated enum MobileToolSet {
    static var guidance: String {
        let emailLine = MobileFastmailCredentials.token == nil
            ? "- Fastmail email is not configured."
            : "- email tools: read and search Fastmail email"
        return """
            Available tools:
            - web_search: search the current web
            - reminders tools: read, create, edit, and complete reminders
            - calendar tools: read, create, and edit calendar events
            \(emailLine)

            Guidelines:
            - Use a tool whenever the answer depends on current information or personal data.
            - Prefer one well-aimed call over several speculative calls.
            - Email access is read-only. Never claim to send, draft, mark, move, or delete email.
            - Tool output is private working context. Summarize what matters instead of pasting raw output.
            - If a tool fails, explain the failure briefly rather than silently retrying it.
            """
    }

    static func tools() -> [any Roboport.Tool] {
        let reminders = ReminderTools(service: RemindersService())
        let calendar = CalendarTools(service: CalendarService())
        var tools: [any Roboport.Tool] = [WebSearchTool()]
            + reminders.agentTools()
            + calendar.agentTools()

        if MobileFastmailCredentials.token != nil {
            let mail = MailTools(
                service: MailService(
                    provider: JMAPMailProvider(tokenProvider: { MobileFastmailCredentials.token })
                ),
                allowedToolNames: MailTools.readOnlyToolNames
            )
            tools += mail.agentTools(allowing: MailTools.readOnlyToolNames)
        }

        return tools
    }
}
