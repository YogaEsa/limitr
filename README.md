# Limitr

**Keep an eye on your Claude Code and Codex limits without leaving the menu bar.**

Limitr is a native, privacy-first macOS menu-bar app for people who use Claude Code, Codex, or both. It turns local activity and account data into a quick view of your remaining usage, current pace, and next reset—without asking you to copy tokens or leave your workflow.

<p align="center">
  <img src="Resources/Assets/preview.gif" alt="Limitr in the menu bar: usage windows, pace, and reset countdowns" width="700">
</p>

## Features

- **Menu-bar dashboard** — See the most relevant usage window at a glance, with an optional notch-adjacent panel for more detail.
- **Claude Code and Codex support** — Monitor either service or both from one native app.
- **Multi-account profiles** — Detect, connect, and switch between local Claude Code and Codex accounts.
- **Usage context** — Track remaining allowance, usage pace, reset countdowns, token history, and model usage.
- **Helpful alerts** — Receive local notifications before a usage window runs out and when it resets.
- **Terminal-friendly CLI** — Use `limitr` in scripts, status bars, and other command-line workflows.
- **Local by design** — Limitr reads existing local sessions; it never asks you to paste an API key.

> Requires macOS 14 Sonoma or newer.

## Requirements

Limitr is a Swift package, so the Swift 6 toolchain that ships with Xcode 16 is all you need.

```sh
xcode-select --install     # Command Line Tools, if you have never installed them
swift --version            # Expect 6.0 or newer
```

## Build from source

Clone the repository and check that the toolchain is happy:

```sh
git clone https://github.com/<your-github-username>/Limitr.git
cd Limitr
swift build
swift test
```

`swift build` produces the `limitr` CLI, which is ready to use immediately:

```sh
swift run limitr            # Codex usage from local session logs
swift run limitr --claude   # Codex and Claude Code usage
```

### Build the menu-bar app

The app needs a real `.app` bundle — `swift run LimitrApp` will not work, because macOS refuses to grant notification permission to a process that has no bundle. Run the block below from the repository root to compile a universal release binary and wrap it:

```sh
swift build -c release --product LimitrApp --arch arm64 --arch x86_64
BIN="$(swift build -c release --product LimitrApp --arch arm64 --arch x86_64 --show-bin-path)"

APP="dist/Limitr.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LimitrApp" "$APP/Contents/MacOS/LimitrApp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Assets/claudeicon.svg Resources/Assets/gpticon.svg "$APP/Contents/Resources/"

ICONSET="$(mktemp -d)/Limitr.iconset"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" Resources/Assets/limitr.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
done
cp "$ICONSET/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Limitr.icns"

codesign --force --sign - "$APP"
open "$APP"
```

That signature is ad-hoc, which is fine for a build you run yourself but not for one you hand to anyone else.

The first launch asks macOS for notification permission, then Limitr appears in the menu bar. Move `dist/Limitr.app` to `/Applications` if you want to keep it.

### Sign and notarize a distributable build

Replace the `codesign` line above with a Developer ID identity, then notarize and staple:

```sh
xcrun notarytool store-credentials "limitr" --apple-id "you@example.com" --team-id "TEAMID"

codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" dist/Limitr.app

ditto -c -k --keepParent dist/Limitr.app dist/Limitr.zip
xcrun notarytool submit dist/Limitr.zip --keychain-profile "limitr" --wait
xcrun stapler staple dist/Limitr.app
```

## Connect your accounts

1. Click the Limitr icon in the menu bar.
2. Choose **Accounts**.
3. Connect Claude Code, Codex, or both.
4. Pick the account that should be active for each service.

For Claude, sign in first with `claude login`. For Codex, sign in with `codex login`. Limitr uses those existing local sessions; it never asks you to paste an API key.

Codex usage is marked stale after 30 minutes without a new rate-limit event. Claude polling follows its minimum interval and backs off automatically after a rate-limit response.

## Privacy

Your credentials and session logs stay on your Mac. Limitr reads Claude credentials from the Keychain through Apple's own `security` tool and reads Codex usage from local session logs. Nothing is sent anywhere except your own usage request to the service you are already signed in to. Local state, credentials, build products, and editor settings are excluded by `.gitignore`.

## Project layout

```text
Sources/
  LimitrApp/       SwiftUI menu-bar application
  LimitrCLI/       JSON command-line reporter
  LimitrCore/      Shared account, provider, usage, and system logic
Tests/             XCTest suite for LimitrCore
Resources/Assets/  App icon, product marks, and preview
```

Run a single test with `swift test --filter <TestClass>/<testMethod>`, for example:

```sh
swift test --filter CodexProviderTests/testMarksOldEventsStale
```
