# Isle for iOS

A minimal, document-like iOS client for Isle. It uses the same in-tree Robo agent and OpenRouter model as the macOS app, with web search, Calendar, Reminders, and read-only Fastmail tools. Completed threads are retained locally; after five idle minutes, Isle starts a new thread while keeping the previous one hidden for future history UI.

## Credentials

For development, add `ISLE_OPENROUTER_KEY` and `ISLE_JMAP_TOKEN` under **Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables** in Xcode. The JMAP token enables the read-only Fastmail tools; the app never exposes mail write tools.

On the first Xcode-run launch, Isle copies each environment value into the device Keychain. Later launches read it from Keychain, so credentials do not need to be embedded in the app or exposed in the UI. TestFlight and ordinary installed-app launches cannot receive Xcode scheme environment variables.

For an already booted Simulator, the equivalent first launch is:

```sh
SIMCTL_CHILD_ISLE_OPENROUTER_KEY="$ISLE_OPENROUTER_KEY" \
SIMCTL_CHILD_ISLE_JMAP_TOKEN="$ISLE_JMAP_TOKEN" \
  xcrun simctl launch --terminate-running-process booted DestinerLabs.IsleMobile
```

Calendar and Reminders request full EventKit access lazily on first use.

## Generate and build

```sh
cd iOS
xcodegen generate
xcodebuild -project IsleMobile.xcodeproj -scheme IsleMobile \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
