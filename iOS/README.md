# Isle for iOS

A minimal, document-like iOS client for Isle. It uses the same in-tree Roboport agent and OpenRouter model as the macOS app, currently without tools. Completed threads are retained locally; after five idle minutes, Isle starts a new thread while keeping the previous one hidden for future history UI.

## API key

For development, add `ISLE_OPENROUTER_KEY` under **Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables** in Xcode.

On the first Xcode-run launch, Isle copies the environment value into the device Keychain. Later launches read it from Keychain, so the key does not need to be embedded in the app or exposed in the UI. TestFlight and ordinary installed-app launches cannot receive Xcode scheme environment variables.

For an already booted Simulator, the equivalent first launch is:

```sh
SIMCTL_CHILD_ISLE_OPENROUTER_KEY="$ISLE_OPENROUTER_KEY" \
  xcrun simctl launch --terminate-running-process booted DestinerLabs.IsleMobile
```

## Generate and build

```sh
cd iOS
xcodegen generate
xcodebuild -project IsleMobile.xcodeproj -scheme IsleMobile \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
