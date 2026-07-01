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
    /// Fired when Tab is pressed while Isle holds focus (switch input mode).
    var onSwitchMode: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
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

        // Enter (submit) while another app is frontmost — e.g. a voice turn where
        // the user clicked away. Passive global monitor; AppDelegate ignores Enter
        // unless Isle is visible. (When Isle holds focus the event is ours, so the
        // global monitor stays silent and the local monitor below handles it.)
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
                self?.onSubmit?()
            default:
                break
            }
        }

        // Keys aimed at Isle while it holds focus (the pill is open). Tab switches
        // mode and is swallowed so the text field doesn't beep / traverse; Enter
        // drives the voice submit path (in text mode it's a no-op here and the
        // event passes through to the field's own onSubmit).
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case UInt16(kVK_Tab):
                self?.onSwitchMode?()
                return nil
            case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
                self?.onSubmit?()
                return event
            default:
                return event
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
