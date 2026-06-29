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
    private let bottomRoom: CGFloat = 12  // breathing room / shadow below
    private let topGap: CGFloat = 6       // gap between the notch and the resting pill

    private var panelSize: NSSize {
        NSSize(width: pillSize.width, height: pillSize.height + topRoom + bottomRoom)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Background agent: no Dock icon, no menu bar.
        NSApp.setActivationPolicy(.accessory)

        let panel = FragmentPanel(
            rootView: FragmentView(
                state: state,
                pillSize: pillSize,
                topRoom: topRoom,
                onQuit: { NSApp.terminate(nil) }
            )
        )
        panel.setContentSize(panelSize)
        self.panel = panel

        // Load (and download on first run) the transcription model.
        dictation.prepare()

        // Hold fn / 🌐 to peek the fragment and dictate; release to hide and transcribe.
        fnMonitor.onChange = { [weak self] pressed in
            guard let self else { return }
            if pressed {
                self.show()
                self.dictation.startRecording()
            } else {
                self.hide()
                self.dictation.finishAndPaste()
            }
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

    private func hide() {
        state.isOpen = false
        // Keep the panel on screen until the collapse animation finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.state.isOpen else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// Center horizontally so the pill rests just below the notch. The panel
    /// extends `topRoom` above the pill, so account for that when placing it.
    private func positionBelowNotch(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.maxY - topGap - (pillSize.height + bottomRoom)
        )
        panel.setFrameOrigin(origin)
    }
}
