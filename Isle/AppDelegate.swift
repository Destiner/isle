//
//  AppDelegate.swift
//  Isle
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FragmentPanel?
    private let fnMonitor = FnKeyMonitor()
    private let state = IslandState()
    private let dictation = DictationManager()

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
                pillSize: pillSize,
                topRoom: topRoom,
                expandedWidth: expandedWidth,
                onQuit: { NSApp.terminate(nil) }
            )
        )
        panel.setContentSize(panelSize)
        self.panel = panel

        // Load (and download on first run) the transcription model.
        dictation.prepare()

        // Stream recognized speech into the pill as the user talks.
        dictation.onPartialTranscript = { [weak self] text in
            self?.state.update(transcript: text)
        }
        // On release: settle the full message before the answer arrives.
        dictation.onFinalTranscript = { [weak self] text in
            self?.state.setFinalTranscript(text)
        }
        // Codex answered → show it in the pill (stays open until the next hold).
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

        // Hold fn / 🌐 to dictate a request; release to send it to Codex and
        // show the answer. The conversation persists across holds; a short tap
        // with no speech keeps the previous answer.
        fnMonitor.onChange = { [weak self] pressed in
            guard let self else { return }
            if pressed {
                self.state.startTurn()
                self.show()
                self.dictation.startRecording()
            } else {
                self.state.beginThinking()
                self.dictation.finishAndRespond()
            }
        }
        // Esc clears the conversation and dismisses the pill.
        fnMonitor.onEscape = { [weak self] in
            self?.dismiss()
        }
        fnMonitor.start()
    }

    private func show() {
        guard let panel else { return }
        positionBelowNotch(panel)
        // orderFrontRegardless avoids stealing focus from the foreground app.
        panel.orderFrontRegardless()
        state.isOpen = true
    }

    /// Clears the conversation and collapses the pill.
    private func dismiss() {
        guard state.isOpen else { return }
        dictation.clearHistory()
        hide()
    }

    private func hide() {
        state.isOpen = false
        // Keep the panel on screen until the collapse animation finishes, then
        // hide it and reset so nothing flashes on the next open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.state.isOpen else { return }
            self.panel?.orderOut(nil)
            self.state.reset()
        }
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
