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
    private lazy var dictation = DictationManager(preferences: preferences)

    // Hosts Isle's reminder + mail tools as a localhost MCP server for Codex to call.
    private var mcpServer: MCPHTTPServer?

    // The last-used input mode, persisted so a relaunch restores it.
    private static let modeKey = "inputMode"

    // The conversation is cleared after the pill sits closed past
    // `preferences.idleTimeout`. Armed on hide, cancelled on show.
    private var idleTimer: Timer?

    private let pillSize = CGSize(width: 150, height: 40)
    private let topRoom: CGFloat = 30     // headroom above the pill for the animation
    private let topGap: CGFloat = 6       // gap between the notch and the resting pill

    // The panel is sized to fit the fully expanded pill (with live transcript),
    // not just the resting state. Empty SwiftUI regions don't capture clicks, so
    // the extra transparent area below the notch stays click-through.
    private let expandedWidth: CGFloat = 380   // width the transcript wraps at
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

        // Restore the last-used mode (falling back to the default on first launch).
        state.mode = UserDefaults.standard.string(forKey: Self.modeKey)
            .flatMap(InputMode.init(rawValue:)) ?? preferences.defaultMode
        Log.app("launch", ["mode": state.mode.rawValue])

        let panel = PillPanel(
            rootView: PillView(
                state: state,
                pillSize: pillSize,
                topRoom: topRoom,
                expandedWidth: expandedWidth,
                onSubmitText: { [weak self] in self?.submitTypedText() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        panel.setContentSize(panelSize)
        self.panel = panel

        // Voice only: load (and download on first run) the transcription model.
        // (prepare() is idempotent, so the lazy load on a later Tab switch is safe.)
        if state.mode == .voice {
            dictation.prepare()
        }

        // Bring up the MCP tool server so Codex can act on Reminders, Calendar, and Mail. Runs
        // for the app's lifetime; `start()` serves until the process exits, so detach.
        if preferences.enableReminderTools || preferences.enableCalendarTools || preferences.enableNotesTools || preferences.enableMusicTools || preferences.enableMailTools || preferences.enableBrowserTools {
            let server = MCPHTTPServer(
                port: preferences.mcpPort,
                reminders: preferences.enableReminderTools ? RemindersService() : nil,
                calendar: preferences.enableCalendarTools ? CalendarService() : nil,
                notes: preferences.enableNotesTools ? NotesService() : nil,
                music: preferences.enableMusicTools ? MusicService() : nil,
                mail: preferences.enableMailTools ? MailService() : nil,
                browser: preferences.enableBrowserTools ? BrowserService(port: preferences.chromeDebuggingPort, headless: preferences.chromeHeadless) : nil)
            mcpServer = server
            Task.detached {
                do {
                    try await server.start()
                } catch {
                    Log.error("mcp.start", "\(error)")
                }
            }
            Log.app("mcp.listening", ["port": preferences.mcpPort])
        }

        // Stream recognized speech into the pill as the user talks.
        dictation.onPartialTranscript = { [weak self] text in
            self?.state.update(transcript: text)
        }
        // On release: settle the full message before the answer arrives.
        dictation.onFinalTranscript = { [weak self] text in
            self?.state.setFinalTranscript(text)
        }
        // Codex answered → show it in the pill (stays open until the next fn-tap),
        // and in voice mode silently re-open the mic so the user can just speak
        // the follow-up (the answer stays on screen until they actually do).
        dictation.onResponse = { [weak self] answer in
            guard let self else { return }
            self.state.showResponse(answer)
            self.armVoiceFollowUp()
        }
        // Codex is calling a tool (web search, a shell command, an Isle MCP tool):
        // show it in the pill's single tool slot; clear back to "Thinking" when it
        // finishes (no next tool yet). A new answer clears it via showResponse.
        dictation.onToolEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case let .begin(_, key): self.state.beginTool(named: key)
            case .end: self.state.endTool()
            }
        }
        // Voice only: the speaker fell quiet after talking — auto-submit, exactly
        // as if Enter had been pressed from listening. Manual Enter still works as
        // an instant override (`onSubmit`).
        dictation.onEndpoint = { [weak self] in
            guard let self, self.preferences.autoSubmitOnSilence,
                  self.state.mode == .voice, self.state.isOpen,
                  self.state.phase == .listening else { return }
            self.state.beginThinking()
            self.dictation.finishAndRespond()
        }
        // Nothing captured, or the request failed: show the error, otherwise fall
        // back to the previous answer (or collapse if there's nothing to show).
        dictation.onNoResponse = { [weak self] error in
            guard let self else { return }
            if let error {
                self.state.showError(error)
                self.armVoiceFollowUp()
            } else if self.state.cancelTurn() {
                self.armVoiceFollowUp()
            } else {
                self.hide()
            }
        }
        // Voice only: speech detected while an answer is shown → flip into
        // listening for the follow-up. The mic is already running (armed by
        // `armVoiceFollowUp`), so we only change phase — the buffer is kept, so
        // the first words aren't lost. A no-op in any other phase.
        dictation.onSpeechStart = { [weak self] in
            guard let self, self.state.mode == .voice, self.state.isOpen,
                  self.state.phase == .responding else { return }
            self.state.startTurn()
            self.dictation.enableLivePreview()
        }

        // Tap fn / 🌐 to toggle Isle: opening starts recording right away — speak
        // freely while the pill is visible. Tapping again hides it (the
        // conversation persists for the next open).
        fnMonitor.onToggle = { [weak self] in
            guard let self else { return }
            if self.state.isOpen {
                if self.state.mode == .voice { self.dictation.cancelRecording() }
                self.hide()
            } else if self.state.hasHistory {
                // Reopening within the idle window (history not yet cleared):
                // restore the last answer instead of starting blank. Voice re-arms
                // the follow-up mic just like it does after an answer lands.
                self.state.restore()
                self.show()
                if self.state.mode == .voice { self.armVoiceFollowUp() }
            } else {
                self.state.startTurn()
                self.show()
                if self.state.mode == .voice { self.dictation.startRecording() }
            }
        }
        // Voice only: Enter alternates listen ⇄ submit while the pill is visible —
        // from listening it sends the speech so far to Codex (an instant override
        // for the automatic silence endpoint); from a shown answer it starts a
        // fresh turn. (In text mode the panel is key, so Enter is handled by the
        // focused field via `onSubmitText`, not this global tap.)
        fnMonitor.onSubmit = { [weak self] in
            guard let self, self.state.mode == .voice, self.state.isOpen else { return }
            switch self.state.phase {
            case .listening:
                self.state.beginThinking()
                self.dictation.finishAndRespond()
            case .responding:
                self.state.startTurn()
                self.dictation.startRecording()
            case .thinking:
                break
            }
        }
        // Tab flips text ⇄ voice while the pill is open (handled by FnKeyMonitor's
        // local monitor, so it only fires when Isle itself has focus).
        fnMonitor.onSwitchMode = { [weak self] in self?.switchMode() }
        // ⌘N while the pill is open clears the conversation and starts fresh.
        fnMonitor.onNewChat = { [weak self] in self?.newChat() }
        fnMonitor.start()
    }

    /// Toggle the input mode while the pill is open, remembering the choice. The
    /// conversation (history + on-screen answer) is kept; the in-progress compose
    /// is reset and the new mode's composer takes over — voice starts recording,
    /// text grabs the field (via `PillView.syncFocus`). Ignored mid-thought.
    private func switchMode() {
        guard state.isOpen, state.phase != .thinking else { return }
        if state.mode == .voice { dictation.cancelRecording() }

        let next: InputMode = state.mode == .text ? .voice : .text
        state.mode = next
        UserDefaults.standard.set(next.rawValue, forKey: Self.modeKey)
        Log.app("mode.switch", ["to": next.rawValue])

        state.startTurn()
        if next == .voice {
            dictation.prepare()        // lazy first load; no-op once loaded
            dictation.startRecording()
        }
    }

    /// Clear the conversation and start a fresh chat without closing the pill
    /// (⌘N). Same clear as the idle timer — the model-facing `history` and the
    /// on-screen answers — then re-arm the current mode's composer so the next
    /// message can go straight in. Only meaningful while the pill is open.
    private func newChat() {
        guard state.isOpen else { return }
        if state.mode == .voice { dictation.cancelRecording() }
        Log.app("chat.new")
        dictation.clearHistory()
        state.reset()
        state.startTurn()
        if state.mode == .voice { dictation.startRecording() }
    }

    /// After an answer is shown in voice mode, silently open the mic and run the
    /// endpoint loop while the pill still reads "Ready". The user can keep reading;
    /// the moment they speak, `onSpeechStart` flips into listening. Hands-free in
    /// both directions — `onEndpoint` already auto-submits from listening.
    private func armVoiceFollowUp() {
        guard preferences.autoListenFollowUp,
              state.mode == .voice, state.isOpen, state.phase == .responding else { return }
        dictation.startRecording(preview: false)
    }

    private func show() {
        guard let panel else { return }
        cancelIdleTimer()
        positionBelowNotch(panel)
        // The panel becomes key in both modes so it receives keystrokes — text
        // needs the field's caret, and voice needs Tab/Enter to reach the local
        // monitor. As a non-activating panel it does this without activating Isle
        // or visually defocusing the frontmost app.
        panel.makeKeyAndOrderFront(nil)
        state.isOpen = true
    }

    /// Send the typed message to Codex. Ignored while Codex is thinking or when
    /// the field is empty. Mirrors the voice submit path: stage the user message,
    /// flip to thinking, then hand the text to the conversation.
    private func submitTypedText() {
        guard state.isOpen, state.phase != .thinking else { return }
        let trimmed = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.setUserMessage(trimmed)
        state.beginThinking()
        dictation.submitText(trimmed)
        // Clear the field only after it's animated out, so the morph shows the
        // text greying into place rather than flashing the placeholder mid-fade.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.state.draft = ""
        }
    }

    private func hide() {
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
            self.dictation.clearHistory()
            self.state.reset()
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
