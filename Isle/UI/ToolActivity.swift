//
//  ToolActivity.swift
//  Isle
//

import SwiftUI

/// A single tool/MCP call surfaced in the pill while Codex works — an icon plus
/// a short present-tense label ("Searching the web…"). Each tool defines its own
/// on-screen identity via `ToolPresentation`. There's no done/failed state: only
/// the running call is shown, and when none is running the pill shows "Thinking".
struct ToolActivity: Identifiable {
    let id: Int
    let icon: String   // SF Symbol name
    let label: String
}

/// Maps a tool name — a Codex builtin (web search) or one of Isle's own MCP tools
/// — to how it should read in the pill. The single seam where a tool's on-screen
/// identity lives; when the tool-event data path lands (streaming out of
/// `CodexClient`'s `--json` log), this is what turns a tool name into a row.
enum ToolPresentation {
    static func activity(forTool name: String) -> (icon: String, label: String) {
        switch name {
        case "web_search", "web.search":
            return ("globe", "Searching the web…")
        case "command_execution":
            return ("terminal", "Running a command…")
        case "file_change":
            return ("pencil", "Editing files…")
        case "create_reminder":
            return ("checklist", "Creating a reminder…")
        case "send_email", "create_draft":
            return ("paperplane", "Working on email…")
        case "browser_navigate":
            return ("safari", "Browsing…")
        default:
            // MCP tools without a bespoke label — match the provider family, else
            // a neutral fallback.
            if name.contains("reminder") { return ("checklist", "Checking reminders…") }
            if name.contains("mail") || name.contains("email") { return ("envelope", "Checking mail…") }
            if name.hasPrefix("browser") { return ("safari", "Browsing…") }
            return ("wrench.and.screwdriver", "Working…")
        }
    }
}

/// One running tool call: icon + label, styled to match the status rows.
struct ToolActivityRow: View {
    var activity: ToolActivity

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: activity.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 16)

            Text(activity.label)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))

            Spacer(minLength: 0)
        }
    }
}

/// A status affordance styled to match the tool rows so they share one visual
/// language: an animated SF Symbol + label. Used for "Thinking" and "Listening".
/// `animating` gates the symbol effect — it must be off when the row isn't the
/// live focus (idle, or the mic merely armed) so the continuous animation doesn't
/// peg the main thread and starve the main-actor voice loops.
struct StatusRow: View {
    var icon: String
    var label: String
    var animating: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 16)
                .symbolEffect(.variableColor.iterative, isActive: animating)

            Text(label)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}
