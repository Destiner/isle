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
/// The global watch is a **self-owned `CGEventTap`**, not
/// `NSEvent.addGlobalMonitorForEvents`. macOS disables an event tap whose process
/// is slow to service it (`kCGEventTapDisabledByTimeout`) or during heavy input
/// (`kCGEventTapDisabledByUserInput`) — and `NSEvent`'s wrapper never re-enables
/// it, so a single main-thread stall silently kills the global fn/Enter monitor
/// for the rest of the process's life (seen after multi-day uptime: fn stops
/// toggling Isle while the OS's own fn action still fires). Owning the tap lets us
/// catch the disable event and call `CGEventTapEnable` to revive it, so the
/// trigger self-heals. The tap is `listenOnly` (passive — it never swallows the
/// key), matching the old global monitors; if it can't be created we fall back to
/// the `NSEvent` global monitors.
///
/// Permissions: a keyboard event tap needs **Input Monitoring**
/// (`CGRequestListenEventAccess`); fn (`.flagsChanged`) alone works under
/// **Accessibility**. We request both. (Global monitoring also requires the App
/// Sandbox off.) The grant requires an app relaunch to take effect.
final class FnKeyMonitor {
    /// Fired on each fn / 🌐 key press — a tap to toggle Isle on/off.
    var onToggle: (() -> Void)?
    /// Fired when Enter / Return is pressed (submit the current dictation).
    var onSubmit: (() -> Void)?
    /// Fired when Tab is pressed while Isle holds focus (switch input mode).
    var onSwitchMode: (() -> Void)?
    /// Fired on ⌘N while Isle holds focus (clear + start a new chat).
    var onNewChat: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localKeyDownMonitor: Any?

    // Only used if the event tap can't be created — the previous NSEvent global
    // monitors, kept as a best-effort fallback (no self-heal).
    private var fallbackFlagsMonitor: Any?
    private var fallbackKeyDownMonitor: Any?

    private var isDown = false

    func start() {
        requestPermissions()
        if !installEventTap() {
            Log.error("fn.tap", "event tap unavailable; falling back to NSEvent global monitors")
            installFallbackMonitors()
        }
        installLocalKeyDownMonitor()
    }

    // MARK: - Global watch (self-owned, self-healing tap)

    /// Install the session-level tap for fn (`.flagsChanged`) and Enter
    /// (`.keyDown`). Returns false if the tap couldn't be created (e.g. the grant
    /// isn't in place yet), so the caller can fall back.
    private func installEventTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: fnTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }
        // Serviced on the main run loop, so the callbacks run on the main thread —
        // they touch main-actor UI state, same as the old NSEvent monitors did.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    /// Routed here from the C tap callback, on the main run loop. Re-enables the
    /// tap when the system has disabled it, otherwise dispatches fn / Enter.
    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        switch type {
        case .flagsChanged: handleFlags(nsEvent)
        case .keyDown: handleGlobalKeyDown(nsEvent)
        default: break
        }
    }

    /// fn toggles Isle: fire only on the press edge, ignore the release.
    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == UInt16(kVK_Function) else { return }
        let pressed = event.modifierFlags.contains(.function)
        guard pressed != isDown else { return }
        isDown = pressed
        if pressed { onToggle?() }
    }

    /// Enter while another app is frontmost — e.g. a voice turn where the user
    /// clicked away. The session tap sees every key, including ones aimed at
    /// Isle's own panel; those are the local monitor's job, so skip them here
    /// (guarding on Isle *not* holding a key window) to avoid a double submit.
    /// This reproduces the old split where a global NSEvent monitor only fired
    /// for events not delivered to Isle. AppDelegate ignores Enter unless the
    /// pill is a visible voice turn.
    private func handleGlobalKeyDown(_ event: NSEvent) {
        guard NSApp.keyWindow == nil else { return }
        switch event.keyCode {
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            onSubmit?()
        default:
            break
        }
    }

    // MARK: - Local watch (Isle holds focus)

    private func installLocalKeyDownMonitor() {
        // Keys aimed at Isle while it holds focus (the pill is open). Tab switches
        // mode and is swallowed so the text field doesn't beep / traverse; Enter
        // drives the voice submit path (in text mode it's a no-op here and the
        // event passes through to the field's own onSubmit).
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case UInt16(kVK_ANSI_N) where event.modifierFlags.contains(.command):
                self?.onNewChat?()
                return nil
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

    // MARK: - Fallback (tap unavailable)

    /// The pre-tap implementation: passive global monitors for fn and Enter. No
    /// self-heal (that's the whole reason the tap is preferred), but keeps Isle
    /// working if the tap can't be created on this system.
    private func installFallbackMonitors() {
        fallbackFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
        }
        fallbackKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
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

        // Input Monitoring — required for the keyboard event tap (`.keyDown`);
        // not covered by Accessibility. Prompts once; grant needs a relaunch.
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
        }
    }
}

/// C tap callback — `@convention(c)`, so it can't capture; it recovers the
/// monitor from `userInfo` and forwards. Returns the event unchanged (the tap is
/// passive / `listenOnly`, so the return value is only a courtesy passthrough).
private let fnTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    if let userInfo {
        Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            .handleTapEvent(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
