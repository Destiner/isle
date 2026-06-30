# Isle

macOS menu-bar-less agent app. Tapping the fn / 🌐 key shows a Dynamic Island-style pill _and_ starts recording the mic, streaming the recognized speech into the pill live (a two-line reverse-teleprompter) for as long as the pill is visible; pressing **Enter** transcribes the full clip locally (Parakeet), sends the transcript to Codex (the `codex` CLI, reusing the user's ChatGPT login), and shows the answer in the pill. The pill walks through three phases — **listening** (teal pulse) → **thinking** (amber pulse) → **responding** ("Ready", no dot) — and stays open with the answer until the next turn. **Enter** alternates listen ⇄ submit: from listening it sends; from a shown answer it starts a fresh listening turn. fn is a **toggle**: tapping it again while the pill is visible hides it (the conversation persists for the next open). The conversation **persists across turns**: each request replays the full history to Codex, and on a new turn the previous answer collapses to a greyed two-line context line above the new turn. **Esc** clears the conversation and dismisses the pill.

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
- `Isle/FragmentView.swift` - The pill UI: emerge/retract animation, the live transcript teleprompter, the answer bubbles (`ResponseBubble`), the phase header (`StatusIndicator`), and `IslandState` (phase + transcript + staged reveal + `assistantTurns`)
- `Isle/FnKeyMonitor.swift` - Global fn-key tap detection (`onToggle`), plus a passive global `.keyDown` monitor for Enter (`onSubmit`) and Esc (`onEscape`)
- `Isle/AudioRecorder.swift` - Mic capture, resampled to 16 kHz mono Float via `AVAudioConverter`; `snapshot()` reads the buffer mid-recording for live partials
- `Isle/DictationManager.swift` - Loads Parakeet (FluidAudio), re-transcribes the growing buffer on a timer for the live preview, and on Enter transcribes the full clip then hands it to `CodexClient`, surfacing the answer via callbacks (`onFinalTranscript` / `onResponse` / `onNoResponse`). `cancelRecording()` stops the mic without sending when Isle is toggled off mid-listen. Owns the model-facing conversation `history` (cleared via `clearHistory()` on Esc)
- `Isle/CodexClient.swift` - Runs `codex exec` non-interactively via an interactive login shell (`zsh -ilc`) and returns the final assistant message. `send(_:history:)` replays prior turns as a transcript so each one-shot run has full context

## Patterns

- Background agent: `LSUIElement = YES` + `setActivationPolicy(.accessory)`, so no Dock icon or menu bar. Quit via right-click on the pill.
- The panel is intentionally taller than the pill (`topRoom`/`bottomRoom` in AppDelegate) so the animation can render outside the pill without being clipped by the window bounds.
- fn is a hardware modifier, not a key, so it's detected via `NSEvent` `.flagsChanged` keyed on `kVK_Function` — not a Carbon hotkey.
- Dictation uses Parakeet **v2** (English-only) via `AsrModels.downloadAndLoad(version: .v2)`; switch to `.v3` for multilingual. No VAD.
- Live preview: the whole buffer is re-transcribed from scratch every ~350 ms (fresh decoder state) — clean text, no token-stitching. The preview is **append-only** (the shown prefix is frozen; the model's corrections to earlier words are dropped from the UI but still reach the final transcript sent to Codex). Words are revealed in **staged** steps so a line-fill and a new-line spill never share a frame, and the two-line viewport masks its top edge so the outgoing line dissolves instead of hard-clipping. `IslandState` and `TranscriptText` share `TranscriptMetrics` so the pacing and the rendered wrapping break lines at the same spots.
- Conversation as turns: each Codex answer is an `AssistantTurn` (stable id) in `IslandState.assistantTurns`. The last turn is "active" (white, full, scroll-capped) only while `phase == .responding`; otherwise it renders as a collapsed two-line greyed context bubble. Because the bubble keeps its identity across that flip, the active→context change **animates as a collapse** (both states share `ResponseBubble`; the measured height is animated in `onPreferenceChange` so it doesn't jump). The view shows the active turn plus one prior while responding, else just the single prior. The model-facing history (user + assistant text) lives separately in `DictationManager` and is replayed to Codex each turn — `codex exec` is one-shot, so context is carried by us, not a resumed session.
- `CodexClient` invokes `codex exec` through `zsh -ilc` (interactive **and** login) so the binary resolves on the user's PATH and inherits the same ChatGPT auth/config a terminal has — no API keys. The interactive flag is load-bearing: `codex` lives in `~/.bun/bin`, which is added in `.zshrc` (interactive-only), so a plain `-lc` login shell can't find it when the app is launched from Finder/launchd. The prompt is piped on stdin and the final message read back from a temp file (`-o`), so neither needs shell escaping and prompt noise is ignored. It runs `--ephemeral --dangerously-bypass-approvals-and-sandbox` from an empty scratch dir with `model_reasoning_effort=low` to keep spoken Q&A snappy. **The sandbox is off on purpose**: spoken requests should be able to act on the machine ("open my Downloads", launch apps). Under the default `-s read-only` sandbox those fail — file writes are "Operation not permitted" and `open` dies with `kLSExecutableIncorrectFormat` (Seatbelt blocks LaunchServices). Trade-off: a misheard command runs with full access, so this is a prototype-grade choice.

## Gotchas

- **App Sandbox is disabled** (`ENABLE_APP_SANDBOX = NO`). Global keyboard monitoring requires it off; re-enabling breaks the fn trigger.
- The app needs **Accessibility permission** (global `.flagsChanged` for fn) and **Microphone permission** (dictation), plus **Input Monitoring permission** (global `.keyDown` for the Enter-to-submit / Esc-to-dismiss monitor). Accessibility does **not** cover keystroke monitoring — `.flagsChanged` (fn) works under it but `.keyDown` (Enter / Esc) needs Input Monitoring, requested via `CGRequestListenEventAccess()`. The grant requires an app **relaunch** to take effect.
- **Hardened runtime requires the `com.apple.security.device.audio-input` entitlement** (`Isle/Isle.entitlements`) — without it macOS silently denies the mic and never shows a prompt.
- TCC ties permissions to the app's code identity (stable: signed `DestinerLabs.Isle`, team `HQR74263JL`), so a grant survives rebuilds. But launching the dev build _from a terminal_ can misattribute the permission prompt to the terminal — launch from Finder/`open` (e.g. a copy in `/Applications`) so prompts attribute to Isle.
- FluidAudio downloads its CoreML model (~450 MB) on first launch to `~/Library/Application Support/FluidAudio/Models/`; cached thereafter.
- The project uses synchronized file groups — new `.swift` files in `Isle/` are compiled automatically. **But** SPM dependencies still require manual `project.pbxproj` edits (no auto-sync for packages).
