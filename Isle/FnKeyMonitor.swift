//
//  FnKeyMonitor.swift
//  Isle
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Watches the physical fn / 🌐 (Globe) key system-wide and reports press/release,
/// plus a global Escape press for dismissal.
///
/// fn is a hardware modifier, not a regular key, so it can't be a Carbon hotkey.
/// Instead we observe `.flagsChanged` events and key off `kVK_Function` (keyCode 63).
///
/// Permissions: `.flagsChanged` monitoring (fn) needs **Accessibility**, but
/// global `.keyDown` monitoring (Esc) is gated separately behind **Input
/// Monitoring** — without it the Esc monitor installs silently but never fires.
/// We request both. (Global monitoring also requires the App Sandbox off.)
final class FnKeyMonitor {
    /// `true` on press, `false` on release.
    var onChange: ((Bool) -> Void)?
    /// Fired when the Escape key is pressed (used to dismiss Isle).
    var onEscape: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyDownMonitor: Any?
    private var isDown = false

    func start() {
        requestPermissions()

        let handle: (NSEvent) -> Void = { [weak self] event in
            guard let self, event.keyCode == UInt16(kVK_Function) else { return }
            let pressed = event.modifierFlags.contains(.function)
            guard pressed != self.isDown else { return }
            self.isDown = pressed
            self.onChange?(pressed)
        }

        // Global: fires while another app is frontmost (the usual case here).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle)
        // Local: covers the case where Isle itself holds focus.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handle(event)
            return event
        }

        // Escape, globally, to dismiss. Passive monitor — it observes without
        // swallowing the event, so it won't interfere with the frontmost app.
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            self?.onEscape?()
        }
    }

    private func requestPermissions() {
        // Accessibility — required for the fn (`.flagsChanged`) monitor.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)

        // Input Monitoring — required for the global Esc (`.keyDown`) monitor;
        // not covered by Accessibility. Prompts once; the grant needs a relaunch.
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
        }
    }
}
