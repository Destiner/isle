//
//  AppDelegate.swift
//  Isle
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PillPanel?
    private let fnMonitor = FnKeyMonitor()
    private let state = IslandState()

    // All tunable behavior lives here (defaults for now; the seam for a future
    // settings UI). Shared with the pieces that read it.
    private let preferences = Preferences()
    private lazy var conversation = Conversation(
        preferences: preferences, tools: IsleToolSet.tools(from: toolProviders))

    // Persists recent chats so ↑ in the empty new-chat state can switch between
    // them. `currentChatID` tracks the live chat so each answer upserts the same
    // record; nil until the first turn lands (or after a fresh/cleared start).
    private let chatStore = ChatStore()
    private var currentChatID: UUID?
    private var currentChatStartedAt: Date?

    // Isle's own tools, built once and handed to the agent. Each provider is
    // present only when its preference is on; the services themselves request
    // their system permissions lazily on first use, so constructing them here
    // triggers no TCC prompts.
    private lazy var toolProviders = IsleToolSet.Providers(
        reminders: preferences.enableReminderTools
            ? ReminderTools(service: RemindersService()) : nil,
        calendar: preferences.enableCalendarTools
            ? CalendarTools(service: CalendarService()) : nil,
        notes: preferences.enableNotesTools ? NotesTools(service: NotesService()) : nil,
        music: preferences.enableMusicTools ? MusicTools(service: MusicService()) : nil,
        mail: preferences.enableMailTools
            ? MailTools(service: MailService(provider: preferences.makeMailProvider())) : nil,
        browser: preferences.enableBrowserTools
            ? BrowserTools(
                service: BrowserService(
                    port: preferences.chromeDebuggingPort,
                    headless: preferences.chromeHeadless)) : nil)

    // The conversation is cleared after the pill sits closed past
    // `preferences.idleTimeout`. Armed on hide, cancelled on show.
    private var idleTimer: Timer?

    private let pillSize = CGSize(width: 150, height: 40)
    private let topRoom: CGFloat = 30     // headroom above the pill for the animation
    private let topGap: CGFloat = 6       // gap between the notch and the resting pill

    // The panel is sized to fit the fully expanded pill (composer + answers),
    // not just the resting state. Empty SwiftUI regions don't capture clicks, so
    // the extra transparent area below the notch stays click-through.
    private let expandedWidth: CGFloat = 380   // width the pill grows to
    private let panelWidth: CGFloat = 420
    private let panelHeight: CGFloat = 440

    private var panelSize: NSSize {
        NSSize(width: panelWidth, height: panelHeight)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug logging (no-op in Release; ISLE_LOG env var overrides the pref).
        Log.configure(enabled: preferences.enableLogging)

        // Background agent: no Dock icon, no menu bar.
        NSApp.setActivationPolicy(.accessory)

        Log.app("launch")

        let panel = PillPanel(
            rootView: PillView(
                state: state,
                pillSize: pillSize,
                topRoom: topRoom,
                expandedWidth: expandedWidth,
                onSubmitText: { [weak self] in self?.submitTypedText() },
                onOpenSwitcher: { [weak self] in self?.openSwitcher() },
                onReinstate: { [weak self] id in self?.reinstate(id) },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        panel.setContentSize(panelSize)
        self.panel = panel

        // The agent answered → show it in the pill (stays open until the next fn-tap).
        conversation.onResponse = { [weak self] answer in
            guard let self else { return }
            self.state.showResponse(answer)
            self.persistCurrentChat()
        }
        // The agent is calling a tool (web search, a shell command, one of Isle's own):
        // show it in the pill's single tool slot; clear back to "Thinking" when it
        // finishes (no next tool yet). A new answer clears it via showResponse.
        conversation.onToolEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case let .begin(_, key): self.state.beginTool(named: key)
            case .end: self.state.endTool()
            }
        }
        // Nothing to send, or the request failed: show the error, otherwise fall
        // back to the previous answer (or collapse if there's nothing to show).
        conversation.onNoResponse = { [weak self] error in
            guard let self else { return }
            if let error {
                self.state.showError(error)
            } else if !self.state.cancelTurn() {
                self.hide()
            }
        }

        // Tap fn / 🌐 to toggle Isle: opening focuses the field so the request can
        // be typed straight away. Tapping again hides it (the conversation
        // persists for the next open).
        fnMonitor.onToggle = { [weak self] in
            guard let self else { return }
            // Breadcrumb for "did the fn trigger even fire?" — this line's absence
            // in app.jsonl means the global monitor never delivered the tap.
            Log.app("fn.toggle", ["open": self.state.isOpen, "hasHistory": self.state.hasHistory])
            if self.state.isOpen {
                self.hide()
            } else if self.state.hasHistory {
                // Reopening within the idle window (history not yet cleared):
                // restore the last answer instead of starting blank.
                self.state.restore()
                self.show()
            } else {
                self.state.startTurn()
                self.show()
            }
        }
        // ⌘N while the pill is open clears the conversation and starts fresh.
        fnMonitor.onNewChat = { [weak self] in self?.newChat() }
        fnMonitor.start()
    }

    /// Clear the conversation and start a fresh chat without closing the pill
    /// (⌘N). Same clear as the idle timer — the model-facing `history` and the
    /// on-screen answers — then re-focus the field so the next message can go
    /// straight in. Only meaningful while the pill is open.
    private func newChat() {
        guard state.isOpen else { return }
        Log.app("chat.new")
        conversation.clearHistory()
        state.reset()
        state.startTurn()
        // A fresh chat: the next answer starts a new record.
        currentChatID = nil
        currentChatStartedAt = nil
    }

    /// Open the recent-chats switcher (↑ in the empty new-chat state). No-op when
    /// nothing's saved yet. Options are passed chronological (oldest first) so the
    /// selection opens on the latest chat and a single ↓ exits.
    private func openSwitcher() {
        let options = Array(chatStore.recentSummaries(limit: 3).reversed())
        guard !options.isEmpty else { return }
        Log.app("chat.switcher.open", ["count": options.count])
        state.openSwitcher(options)
    }

    /// Reinstate a saved chat: restore its transcript into the model-facing
    /// history and its answers on screen, then continue it as the live chat so
    /// later answers update the same record. There's no server-side session to
    /// resume — context is carried by replaying the transcript.
    private func reinstate(_ id: UUID) {
        guard let record = chatStore.record(id: id) else { state.closeSwitcher(); return }
        conversation.loadHistory(record.turns.map {
            Conversation.Turn(role: $0.role == .user ? .user : .assistant, text: $0.text)
        })
        state.reinstate(assistantTexts: record.turns.filter { $0.role == .assistant }.map(\.text))
        currentChatID = record.id
        currentChatStartedAt = record.startedAt
        Log.app("chat.reinstate")
    }

    /// Save the live chat after an answer lands (incremental, crash-safe). The
    /// chat gets its id + start time on its first turn; later answers update it
    /// in place. Empty conversations are never written.
    private func persistCurrentChat() {
        let turns = conversation.currentHistory.map {
            StoredTurn(role: $0.role == .user ? .user : .assistant, text: $0.text)
        }
        guard !turns.isEmpty else { return }
        if currentChatID == nil {
            currentChatID = UUID()
            currentChatStartedAt = Date()
        }
        chatStore.save(id: currentChatID!, startedAt: currentChatStartedAt ?? Date(), turns: turns)
    }

    private func show() {
        guard let panel else { return }
        cancelIdleTimer()
        positionBelowNotch(panel)
        // The panel becomes key so it receives keystrokes — the field needs the
        // caret, and ⌘N has to reach the local monitor. As a non-activating panel
        // it does this without activating Isle or visually defocusing the
        // frontmost app.
        panel.makeKeyAndOrderFront(nil)
        // macOS 26 ignores this panel's `.canJoinAllSpaces` (verified live: the flag
        // is set but the WindowServer pins the window to the Space it was created on),
        // so fn on another desktop steals focus but renders the pill back on the
        // origin Space. Explicitly move it onto the active Space on every show — the
        // one thing proven to unstick it (see PillPanel.moveToActiveSpace).
        panel.moveToActiveSpace()
        state.isOpen = true
        // `key` distinguishes the two failure shapes: key but not visible → a
        // Space/compositing issue; not key → makeKeyAndOrderFront was refused.
        Log.app("show", ["key": panel.isKeyWindow])
    }

    /// Send the typed message to Codex. Ignored while Codex is thinking or when
    /// the field is empty: stage the user message, flip to thinking, then hand the
    /// text to the conversation.
    private func submitTypedText() {
        guard state.isOpen, state.phase != .thinking else { return }
        let trimmed = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.setUserMessage(trimmed)
        state.beginThinking()
        conversation.submit(trimmed)
        // Clear the field only after it's animated out, so the morph shows the
        // text greying into place rather than flashing the placeholder mid-fade.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.state.draft = ""
        }
    }

    private func hide() {
        Log.app("hide")
        state.isOpen = false
        armIdleTimer()
        // Keep the panel on screen until the collapse animation finishes, then
        // hide it and reset so nothing flashes on the next open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.state.isOpen else { return }
            self.panel?.orderOut(nil)
            self.state.prepareForClose()
        }
    }

    /// While the pill is closed, count down to clearing the conversation so a
    /// later open starts fresh: both the model-facing `history` and the on-screen
    /// answers (kept across hide by `prepareForClose` so a reopen within this
    /// window can restore the last one).
    private func armIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: preferences.idleTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            Log.app("idle.clear")
            self.conversation.clearHistory()
            self.state.reset()
            // The conversation is gone; the next one starts a new record (the
            // cleared chat stays saved and reachable via the switcher).
            self.currentChatID = nil
            self.currentChatStartedAt = nil
        }
    }

    private func cancelIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// Center horizontally so the pill's top edge rests just below the notch.
    /// The pill sits `topRoom` below the panel's top edge (headroom for the
    /// emerge animation), and the panel grows downward from there, so the
    /// origin is derived from the panel height rather than the pill height.
    private func positionBelowNotch(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.maxY - topGap + topRoom - panel.frame.height
        )
        panel.setFrameOrigin(origin)
    }
}
