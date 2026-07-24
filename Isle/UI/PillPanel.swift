//
//  PillPanel.swift
//  Isle
//

import AppKit
import SwiftUI

/// A borderless, transparent, floating panel that hosts SwiftUI content.
/// Behaves like a Spotlight/Raycast-style overlay rather than a normal window.
final class PillPanel: NSPanel {
    /// Draw over the menu bar/notch and full-screen apps, and don't slide during
    /// Spaces switches. `.canJoinAllSpaces` is included but **not relied on** — on
    /// macOS 26 the WindowServer ignores it here and pins the panel to the Space it
    /// was created on (verified live), so `moveToActiveSpace()` does the real work.
    static let overlayCollectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

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

        // Appear on every Space, including over fullscreen apps (see the constant).
        collectionBehavior = Self.overlayCollectionBehavior

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

    /// Move the panel onto the currently active Space. `.canJoinAllSpaces` is
    /// ignored for this window on macOS 26 (the flag is set yet the WindowServer
    /// keeps it on a single, stale Space), so `AppDelegate.show()` calls this on
    /// every present to put the pill where fn was actually pressed. Uses the
    /// private CGS/SkyLight Space API — the same mechanism window managers use, and
    /// the operation needs no elevated access when acting on our own window. This
    /// is a locally-installed dev tool, never shipped through the App Store.
    /// A no-op if the connection or active Space can't be resolved (falls back to
    /// AppKit's placement).
    func moveToActiveSpace() {
        let cid = CGSMainConnectionID()
        guard let space = Self.activeSpaceID(cid) else { return }
        CGSMoveWindowsToManagedSpace(cid, [windowNumber] as CFArray, space)
    }

    /// The active Space id of the main display, read from the WindowServer's
    /// managed-display list (`Current Space` → `ManagedSpaceID`).
    private static func activeSpaceID(_ cid: CGSConnectionID) -> CGSSpaceID? {
        guard let displays = CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        for display in displays {
            if let current = display["Current Space"] as? [String: Any],
               let id = current["ManagedSpaceID"] as? Int {
                return CGSSpaceID(id)
            }
        }
        return nil
    }
}

// MARK: - Private CoreGraphics Services (SkyLight) Space API

private typealias CGSConnectionID = UInt32
private typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?

@_silgen_name("CGSMoveWindowsToManagedSpace")
private func CGSMoveWindowsToManagedSpace(_ cid: CGSConnectionID, _ windows: CFArray, _ space: CGSSpaceID)
