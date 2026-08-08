//
//  FnKeyMonitor.swift
//  Isle
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Watches the physical fn / 🌐 (Globe) key system-wide and reports each tap.
///
/// fn is a hardware modifier, not a regular key, so it can't be a Carbon hotkey.
/// Instead we observe `.flagsChanged` events and key off `kVK_Function` (keyCode 63).
///
/// The global watch is a **self-owned `CGEventTap`**, not
/// `NSEvent.addGlobalMonitorForEvents`. macOS disables an event tap whose process
/// is slow to service it (`kCGEventTapDisabledByTimeout`) or during heavy input
/// (`kCGEventTapDisabledByUserInput`) — and `NSEvent`'s wrapper never re-enables
/// it, so a single main-thread stall silently kills the global fn monitor for the
/// rest of the process's life (seen after multi-day uptime: fn stops toggling Isle
/// while the OS's own fn action still fires). Owning the tap lets us catch the
/// disable event and call `CGEventTapEnable` to revive it, so the trigger
/// self-heals. The tap is `listenOnly` (passive — it never swallows the key),
/// matching the old global monitor; if it can't be created we fall back to the
/// `NSEvent` global monitor.
///
/// Permissions: fn (`.flagsChanged`) works under **Accessibility**. (Global
/// monitoring also requires the App Sandbox off.) The grant requires an app
/// relaunch to take effect.
final class FnKeyMonitor {
    /// Fired on each fn / 🌐 key press — a tap to toggle Isle on/off.
    var onToggle: (() -> Void)?
    /// Fired on ⌘N while Isle holds focus (clear + start a new chat).
    var onNewChat: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localKeyDownMonitor: Any?

    // Only used if the event tap can't be created — the previous NSEvent global
    // monitor, kept as a best-effort fallback (no self-heal).
    private var fallbackFlagsMonitor: Any?

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

    /// Install the session-level tap for fn (`.flagsChanged`). Returns false if
    /// the tap couldn't be created (e.g. the grant isn't in place yet), so the
    /// caller can fall back.
    private func installEventTap() -> Bool {
        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
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
    /// tap when the system has disabled it, otherwise dispatches fn.
    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        guard type == .flagsChanged, let nsEvent = NSEvent(cgEvent: event) else { return }
        handleFlags(nsEvent)
    }

    /// fn toggles Isle: fire only on the press edge, ignore the release.
    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == UInt16(kVK_Function) else { return }
        let pressed = event.modifierFlags.contains(.function)
        guard pressed != isDown else { return }
        isDown = pressed
        if pressed { onToggle?() }
    }

    // MARK: - Local watch (Isle holds focus)

    private func installLocalKeyDownMonitor() {
        // Keys aimed at Isle while it holds focus (the pill is open). ⌘N starts a
        // new chat and is swallowed; everything else passes through to the field.
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_ANSI_N),
                  event.modifierFlags.contains(.command) else { return event }
            self?.onNewChat?()
            return nil
        }
    }

    // MARK: - Fallback (tap unavailable)

    /// The pre-tap implementation: a passive global monitor for fn. No self-heal
    /// (that's the whole reason the tap is preferred), but keeps Isle working if
    /// the tap can't be created on this system.
    private func installFallbackMonitors() {
        fallbackFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
        }
    }

    private func requestPermissions() {
        // Accessibility — required for the fn (`.flagsChanged`) monitor.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
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
