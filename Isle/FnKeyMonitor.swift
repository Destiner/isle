//
//  FnKeyMonitor.swift
//  Isle
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Watches the physical fn / 🌐 (Globe) key system-wide and reports each tap,
/// plus global Enter (submit) presses.
///
/// fn is a hardware modifier, not a regular key, so it can't be a Carbon hotkey.
/// Instead we observe `.flagsChanged` events and key off `kVK_Function` (keyCode 63).
///
/// Permissions: `.flagsChanged` monitoring (fn) needs **Accessibility**, but
/// global `.keyDown` monitoring (Enter) is gated separately behind **Input
/// Monitoring** — without it those monitors install silently but never fire.
/// We request both. (Global monitoring also requires the App Sandbox off.)
final class FnKeyMonitor {
    /// Fired on each fn / 🌐 key press — a tap to toggle Isle on/off.
    var onToggle: (() -> Void)?
    /// Fired when Enter / Return is pressed (submit the current dictation).
    var onSubmit: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyDownMonitor: Any?
    private var isDown = false

    func start() {
        requestPermissions()

        // fn toggles Isle: fire only on the press edge, ignore the release.
        let handle: (NSEvent) -> Void = { [weak self] event in
            guard let self, event.keyCode == UInt16(kVK_Function) else { return }
            let pressed = event.modifierFlags.contains(.function)
            guard pressed != self.isDown else { return }
            self.isDown = pressed
            if pressed { self.onToggle?() }
        }

        // Global: fires while another app is frontmost (the usual case here).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle)
        // Local: covers the case where Isle itself holds focus.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handle(event)
            return event
        }

        // Enter (submit), globally. Passive monitor — it observes without
        // swallowing the event, so it won't interfere with the frontmost app.
        // AppDelegate ignores Enter unless Isle is visible.
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
                self?.onSubmit?()
            default:
                break
            }
        }
    }

    private func requestPermissions() {
        // Accessibility — required for the fn (`.flagsChanged`) monitor.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)

        // Input Monitoring — required for the global Enter (`.keyDown`)
        // monitor; not covered by Accessibility. Prompts once; grant needs a relaunch.
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
        }
    }
}
