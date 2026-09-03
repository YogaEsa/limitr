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

Limitr is a pure Swift package (no `.xcodeproj`), so the free **Command Line Tools** are enough —
you do not need to install the full Xcode.app from the App Store.

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

`swift run LimitrApp` will not work — macOS refuses notification permission to a process with
no `.app` bundle. Build and wrap one instead:

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

This signs ad-hoc — fine to run yourself, not for handing to anyone else. First launch asks for
notification permission, then Limitr shows up in the menu bar. Move `dist/Limitr.app` to
`/Applications` to keep it.

### Releasing a new version (maintainers)

`Scripts/` is gitignored, so `Scripts/release.sh` only exists in a maintainer's local checkout.
If you have it:

```sh
./Scripts/release.sh
```

This builds `dist/Limitr.app`, zips it to `dist/Limitr.app.zip`, and prints its `sha256`. Then:

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist` to the new version.
2. Tag the commit: `git tag -a vX.Y.Z -m "vX.Y.Z"` and `git push origin vX.Y.Z`.
3. Create a GitHub Release from that tag and upload `dist/Limitr.app.zip`.
4. Update `version` and `sha256` in `Casks/limitr.rb` to match, commit, and push to `main`.
5. Once that release exists, add a "Install via Homebrew" section back to this README
   (`brew tap yogaesa/limitr https://github.com/YogaEsa/limitr && brew install --cask limitr`).

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
