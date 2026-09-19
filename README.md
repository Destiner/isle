# Isle

A personal AI assistant for macOS and iOS. On Mac, tap **fn / 🌐** to open a small floating pill, type a request, and press Enter.

## How it works

Isle runs an agent loop locally, using models through OpenRouter. It can work with your calendar, reminders, email, and maps. On macOS, it can also use Apple Notes, control music, browse the web through Chrome, and run shell commands.

Conversations carry context across turns. API credentials are stored in Keychain or supplied through environment variables.

## Tech stack

- **Swift + SwiftUI**, with AppKit on macOS
- **Roboport**, an in-tree Swift agent engine
- **OpenRouter** for model inference
- **EventKit, MapKit, AppleScript, and Fastmail’s JMAP API** for personal tools
- **Chrome DevTools Protocol** for browser automation
- **Model Context Protocol (MCP)** for tool definitions and external integrations
