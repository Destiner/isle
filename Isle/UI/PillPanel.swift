//
//  PillPanel.swift
//  Isle
//

import AppKit
import SwiftUI

/// A borderless, transparent, floating panel that hosts SwiftUI content.
/// Behaves like a Spotlight/Raycast-style overlay rather than a normal window.
final class PillPanel: NSPanel {
    init(rootView: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar                      // draw over the menu bar / notch
        isOpaque = false                        // allow transparency
        backgroundColor = .clear                // no window chrome
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        // Appear on every Space, including over fullscreen apps.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = contentRect(forFrameRect: frame)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    // Borderless panels can't become key by default; we need keyboard input.
    override var canBecomeKey: Bool { true }

    // Swallow Escape: it no longer dismisses the pill, and overriding here keeps
    // the default NSResponder beep from firing when the field is focused.
    override func cancelOperation(_ sender: Any?) {}
}
