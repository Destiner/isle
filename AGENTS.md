# Isle

macOS menu-bar-less agent app. Holding the fn / 🌐 key shows a Dynamic Island-style clock pill *and* records the mic; on release it transcribes the speech locally (Parakeet) and copies the text to the clipboard.

## Commands

- `xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Debug -destination 'platform=macOS' build` - Build
- `xcodebuild test -project Isle.xcodeproj -scheme Isle -destination 'platform=macOS'` - Run tests
- `open $(xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Debug -showBuildSettings | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2}/ FULL_PRODUCT_NAME /{n=$2}END{print d"/"n}')` - Launch the built app

## Stack

- Swift 5, SwiftUI + AppKit + AVFoundation, deployment target macOS 26.3 (Apple Silicon)
- [FluidAudio](https://github.com/FluidInference/FluidAudio) (SPM) — Parakeet speech-to-text on CoreML / Neural Engine

## Structure

- `Isle/IsleApp.swift` - `@main` entry; no real scene (`Settings {}`), delegates to AppDelegate
- `Isle/AppDelegate.swift` - Lifecycle, panel placement, show/hide, layout constants, fn wiring
- `Isle/FragmentPanel.swift` - Borderless non-activating floating `NSPanel`
- `Isle/FragmentView.swift` - The pill UI + emerge/retract animation (`IslandState`)
- `Isle/FnKeyMonitor.swift` - Global fn-key press/release detection
- `Isle/AudioRecorder.swift` - Mic capture, resampled to 16 kHz mono Float via `AVAudioConverter`
- `Isle/DictationManager.swift` - Loads Parakeet (FluidAudio), transcribes, copies to clipboard

## Patterns

- Background agent: `LSUIElement = YES` + `setActivationPolicy(.accessory)`, so no Dock icon or menu bar. Quit via right-click on the pill.
- The panel is intentionally taller than the pill (`topRoom`/`bottomRoom` in AppDelegate) so the animation can render outside the pill without being clipped by the window bounds.
- fn is a hardware modifier, not a key, so it's detected via `NSEvent` `.flagsChanged` keyed on `kVK_Function` — not a Carbon hotkey.
- Dictation uses Parakeet **v2** (English-only) via `AsrModels.downloadAndLoad(version: .v2)`; switch to `.v3` for multilingual. Transcription is batch (record while held → transcribe on release), no VAD.

## Gotchas

- **App Sandbox is disabled** (`ENABLE_APP_SANDBOX = NO`). Global keyboard monitoring requires it off; re-enabling breaks the fn trigger.
- The app needs **Accessibility permission** (global key events + posting the synthetic ⌘V) and **Microphone permission** (dictation).
- **Hardened runtime requires the `com.apple.security.device.audio-input` entitlement** (`Isle/Isle.entitlements`) — without it macOS silently denies the mic and never shows a prompt.
- TCC ties permissions to the app's code identity (stable: signed `DestinerLabs.Isle`, team `HQR74263JL`), so a grant survives rebuilds. But launching the dev build *from a terminal* can misattribute the permission prompt to the terminal — launch from Finder/`open` (e.g. a copy in `/Applications`) so prompts attribute to Isle.
- FluidAudio downloads its CoreML model (~450 MB) on first launch to `~/Library/Application Support/FluidAudio/Models/`; cached thereafter.
- The project uses synchronized file groups — new `.swift` files in `Isle/` are compiled automatically. **But** SPM dependencies still require manual `project.pbxproj` edits (no auto-sync for packages).
