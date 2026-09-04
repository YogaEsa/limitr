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

## Install via Homebrew

```sh
brew tap yogaesa/limitr https://github.com/YogaEsa/limitr
brew install --cask limitr
```

Limitr is ad-hoc signed (no Apple Developer ID yet). If macOS blocks the first launch as
unidentified, run `xattr -cr /Applications/Limitr.app`.

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
git clone https://github.com/YogaEsa/limitr.git
cd limitr
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
no `.app` bundle. Build and wrap one with the build script:

```sh
./Scripts/build-app.sh
```

This compiles a universal release binary, wraps it into `dist/Limitr.app`, generates the app
icon, and signs it ad-hoc. First launch asks for notification permission, then Limitr shows up
in the menu bar. Move `dist/Limitr.app` to `/Applications` to keep it.

## Connect your accounts

1. Click the Limitr icon in the menu bar.
2. Choose **Accounts**.
3. Connect Claude Code, Codex, or both.
4. Pick the account that should be active for each service.

For Claude, sign in first with `claude login`. For Codex, sign in with `codex login`. Limitr uses those existing local sessions; it never asks you to paste an API key.

Codex usage is marked stale after 30 minutes without a new rate-limit event. Claude polling follows its minimum interval and backs off automatically after a rate-limit response.

### YOLO mode

The lightning-bolt button on an account row opens that CLI with its own safety prompts turned
off — `claude --dangerously-skip-permissions` or `codex --dangerously-bypass-approvals-and-sandbox`.
The agent then edits files and runs commands without asking you first. Limitr asks for
confirmation before opening one, but the risk after that is the CLI's, not Limitr's: use it only
in a directory you are willing to let an agent change unattended.

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

## License

[MIT](LICENSE) — do what you like with it, keep the copyright notice, no warranty.

Limitr is not affiliated with, endorsed by, or sponsored by Anthropic or OpenAI. "Claude" and
"Codex" are the trademarks of their respective owners, and the product marks in
`Resources/Assets/` are used only to identify which service a reading belongs to.
