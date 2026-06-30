//
//  AppDelegate.swift
//  Isle
//

import AppKit
import SwiftUI

/// How the user composes a request. Text is the default; voice is kept wired but
/// unused for now (flip this constant to bring it back).
enum InputMode {
    case voice
    case text
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FragmentPanel?
    private let fnMonitor = FnKeyMonitor()
    private let state = IslandState()
    private let dictation = DictationManager()

    private let mode: InputMode = .text

    // After this long with the pill closed, the conversation is cleared so the
    // next open starts fresh. Armed on hide, cancelled on show.
    private let idleTimeout: TimeInterval = 5 * 60
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
        // Background agent: no Dock icon, no menu bar.
        NSApp.setActivationPolicy(.accessory)

        let panel = FragmentPanel(
            rootView: FragmentView(
                state: state,
                mode: mode,
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
        if mode == .voice {
            dictation.prepare()
        }

        // Stream recognized speech into the pill as the user talks.
        dictation.onPartialTranscript = { [weak self] text in
            self?.state.update(transcript: text)
        }
        // On release: settle the full message before the answer arrives.
        dictation.onFinalTranscript = { [weak self] text in
            self?.state.setFinalTranscript(text)
        }
        // Codex answered → show it in the pill (stays open until the next fn-tap).
        dictation.onResponse = { [weak self] answer in
            self?.state.showResponse(answer)
        }
        // Nothing captured, or the request failed: show the error, otherwise fall
        // back to the previous answer (or collapse if there's nothing to show).
        dictation.onNoResponse = { [weak self] error in
            guard let self else { return }
            if let error {
                self.state.showResponse("⚠️ \(error)")
            } else if !self.state.cancelTurn() {
                self.hide()
            }
        }

        // Tap fn / 🌐 to toggle Isle: opening starts recording right away — speak
        // freely while the pill is visible. Tapping again hides it (the
        // conversation persists for the next open).
        fnMonitor.onToggle = { [weak self] in
            guard let self else { return }
            if self.state.isOpen {
                if self.mode == .voice { self.dictation.cancelRecording() }
                self.hide()
            } else {
                self.state.startTurn()
                self.show()
                if self.mode == .voice { self.dictation.startRecording() }
            }
        }
        // Voice only: Enter alternates listen ⇄ submit while the pill is visible —
        // from listening it sends the speech so far to Codex; from a shown answer
        // it starts a fresh turn. (In text mode the panel is key, so Enter is
        // handled by the focused field via `onSubmitText`, not this global tap.)
        fnMonitor.onSubmit = { [weak self] in
            guard let self, self.mode == .voice, self.state.isOpen else { return }
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
        fnMonitor.start()
    }

    private func show() {
        guard let panel else { return }
        cancelIdleTimer()
        positionBelowNotch(panel)
        if mode == .text {
            // Text mode needs the field to receive keystrokes. The panel is a
            // non-activating panel, so it becomes key (caret + typing) without
            // activating Isle or visually defocusing the frontmost app.
            panel.makeKeyAndOrderFront(nil)
        } else {
            // orderFrontRegardless avoids stealing focus from the foreground app.
            panel.orderFrontRegardless()
        }
        state.isOpen = true
    }

    /// Send the typed message to Codex. Ignored while Codex is thinking or when
    /// the field is empty. Mirrors the voice submit path: stage the user message,
    /// flip to thinking, then hand the text to the conversation.
    private func submitTypedText() {
        guard state.isOpen, state.phase != .thinking else { return }
        let trimmed = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.draft = ""
        state.beginThinking()
        dictation.submitText(trimmed)
    }

    private func hide() {
        state.isOpen = false
        armIdleTimer()
        // Keep the panel on screen until the collapse animation finishes, then
        // hide it and reset so nothing flashes on the next open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.state.isOpen else { return }
            self.panel?.orderOut(nil)
            self.state.reset()
        }
    }

    /// While the pill is closed, count down to clearing the model-facing
    /// conversation history so a later open starts a new conversation. (The
    /// on-screen state is already cleared by `hide()`; only `history` persists.)
    private func armIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { [weak self] _ in
            self?.dictation.clearHistory()
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
