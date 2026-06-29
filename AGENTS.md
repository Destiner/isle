# Isle

macOS menu-bar-less agent app: a Dynamic Island-style pill that springs out from under the notch while the fn / 🌐 key is held, showing a live clock.

## Commands

- `xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Debug -destination 'platform=macOS' build` - Build
- `xcodebuild test -project Isle.xcodeproj -scheme Isle -destination 'platform=macOS'` - Run tests
- `open $(xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Debug -showBuildSettings | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2}/ FULL_PRODUCT_NAME /{n=$2}END{print d"/"n}')` - Launch the built app

## Stack

- Swift 5, SwiftUI + AppKit, deployment target macOS 26.3
- No external dependencies

## Structure

- `Isle/IsleApp.swift` - `@main` entry; no real scene (`Settings {}`), delegates to AppDelegate
- `Isle/AppDelegate.swift` - Lifecycle, panel placement, show/hide, layout constants
- `Isle/FragmentPanel.swift` - Borderless non-activating floating `NSPanel`
- `Isle/FragmentView.swift` - The pill UI + emerge/retract animation (`IslandState`)
- `Isle/FnKeyMonitor.swift` - Global fn-key press/release detection

## Patterns

- Background agent: `LSUIElement = YES` + `setActivationPolicy(.accessory)`, so no Dock icon or menu bar. Quit via right-click on the pill.
- The panel is intentionally taller than the pill (`topRoom`/`bottomRoom` in AppDelegate) so the animation can render outside the pill without being clipped by the window bounds.
- fn is a hardware modifier, not a key, so it's detected via `NSEvent` `.flagsChanged` keyed on `kVK_Function` — not a Carbon hotkey.

## Gotchas

- **App Sandbox is disabled** (`ENABLE_APP_SANDBOX = NO`). Global keyboard monitoring requires it off; re-enabling breaks the fn trigger.
- The app needs **Accessibility permission** (prompted on first launch) or no global key events arrive.
- The project uses synchronized file groups — new files dropped in `Isle/` are compiled automatically; no `project.pbxproj` edits needed.
