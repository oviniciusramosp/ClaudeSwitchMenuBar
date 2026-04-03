# Claude Switch Knowledge Base

This document is the operational knowledge base for the `Claude Switch` app. It is intended to be useful both for humans and for coding agents such as Codex and Claude Code.

## Purpose

`Claude Switch` is a native macOS menu bar app that:
- switches between multiple saved Claude Code accounts
- tracks Claude weekly usage and pace
- tracks Codex usage in a separate tab
- can restart Claude Code automatically after account switches
- can check for app updates from GitHub Releases
- can open at login

The project is a Swift Package that builds a menu bar `.app` bundle through a custom shell script.

## Current Platform Support

- Minimum supported OS: `macOS 15`
- App type: menu bar app (`LSUIElement = true`)
- Build system: Swift Package Manager

## Source Layout

- `Sources/ClaudeSwitchMenuBar/ClaudeSwitchMenuBarApp.swift`
  Primary app entry point, menu bar UI, account management UI, settings UI, tab selector, launch-at-login preference, and high-level app state.

- `Sources/ClaudeSwitchMenuBar/ClaudeUsage.swift`
  Claude usage models and API integration, normalization of utilization values, pace logic, weekly reset override handling, and token cache logic.

- `Sources/ClaudeSwitchMenuBar/CodexUsage.swift`
  Codex usage models, auth refresh flow, usage fetching, reset handling, and Codex-specific pace logic.

- `Sources/ClaudeSwitchMenuBar/AppUpdater.swift`
  GitHub Releases update checker/installer, `gh` CLI token fallback, download/unpack/install flow.

- `build-app.sh`
  Builds the release executable, assembles the `.app`, copies bundled resources, writes `Info.plist`, and creates `dist/Claude Switch.zip`.

- `ThirdParty/cc-account-switcher/`
  Vendored copy of `cc-account-switcher`, including the `ccswitch.sh` script and upstream license.

## Core Runtime Model

The app is centered around `AccountStore` in `ClaudeSwitchMenuBarApp.swift`.

It owns:
- current Claude account state
- managed Claude accounts
- Claude usage snapshots by email
- current Codex snapshot
- settings state
- update state
- launch-at-login preference

Important behavior:
- The app refreshes Claude and Codex usage periodically.
- Claude account switching is routed through the vendored `ccswitch.sh`.
- Settings are persisted via `@AppStorage` and `UserDefaults`.

## Claude Account Switching

Claude switching uses the vendored `cc-account-switcher` script rather than requiring a separate external install.

Lookup order for the switcher script:
1. bundled app resource: `Contents/Resources/ccswitch.sh`
2. repo-local development copy: `ThirdParty/cc-account-switcher/ccswitch.sh`
3. legacy fallback: `~/.local/share/cc-account-switcher/ccswitch.sh`

Main Claude workflows:
- `Add Current Account`
  Saves the currently authenticated Claude account into the managed account sequence.

- `Browser Login`
  Logs out, opens Claude login, then saves the newly authenticated account when login completes.

- `Switch`
  Switches the Claude account using `ccswitch.sh`.
  If enabled, the app quits Claude Desktop first and relaunches it after the switch.

Important local data used by switching:
- `~/.claude-switch-backup/sequence.json`
- Claude auth/config files in `~/.claude/.claude.json` or `~/.claude.json`

## Claude Usage

Claude usage comes from the Anthropic OAuth usage endpoint.

Key details:
- endpoint: `https://api.anthropic.com/api/oauth/usage`
- app uses OAuth access token + refresh token
- credentials are read from the Claude Code keychain entry / local credential storage
- refreshed credentials are cached locally

Important normalization rule:
- Claude usage values can come back as whole-number percentages
- example: `1.0` means `1%`, not `100%`
- code must normalize `>= 1` by dividing by `100`

This rule lives in:
- `ClaudeUsage.swift` -> `normalizedUtilization(_:)`

Weekly usage logic:
- app displays `All models weekly usage`
- pace is calculated against elapsed progress through the current weekly window
- manual weekly reset override exists per Claude account

Pace thresholds:
- `onPace`
- `warning`
- `over`

The menu bar ring should follow the same pace logic as the detailed UI.

## Codex Usage

Codex is read-only in this app. It does not switch Codex accounts.

Codex integration reads:
- `~/.codex/auth.json`
- `~/.codex/config.toml`

Usage source:
- base URL defaults to `https://chatgpt.com/backend-api`
- current usage endpoint resolution is handled in `CodexUsage.swift`

Windows used:
- `primary_window` for session usage
- `secondary_window` for weekly usage

Important reset handling:
- prefer `reset_after_seconds` when available
- use `reset_at` only as fallback

## Menu Bar UI

The menu bar label can show:
- Claude usage ring
- Codex usage ring

Optional:
- percentage text to the right of the ring

Current design notes:
- ring is custom-drawn with AppKit
- no center icon is currently shown
- selector above content is a custom segmented-toggle style control, not native `TabView`

## Settings

Current settings areas:
- General
- Updates
- Weekly Reset Override

General includes:
- open at login
- auto-restart Claude Code after switch
- show usage percentage next to menu bar chart
- choose whether menu bar chart tracks Claude or Codex

Updates includes:
- automatic install from GitHub Releases
- manual `Check Now`

Weekly Reset Override includes:
- per-Claude-account manual override
- weekday
- time

## Launch At Login

Launch-at-login uses:
- `ServiceManagement`
- `SMAppService.mainApp`

Important implementation detail:
- the app should not silently register itself on first launch
- instead it should initialize its toggle from the current system state and only register/unregister after explicit user action

## GitHub Updater

Updater behavior:
- checks latest release from GitHub Releases
- compares release version to `CFBundleShortVersionString`
- downloads `Claude Switch.zip`
- unpacks the `.app`
- stages replacement and relaunches the app

Repository:
- `oviniciusramosp/ClaudeSwitchMenuBar`

Authentication:
- UI no longer exposes a manual token field
- updater falls back to `gh auth token` automatically when needed

Important updater constraints:
- app should live in `~/Applications` for self-update
- installer now uses staged replacement + backup
- avoid destructive `rm -rf currentApp` before a valid replacement is ready

## Build and Release Flow

Development:
```bash
swift run ClaudeSwitchMenuBar
```

Validation:
```bash
swift test
```

Release build:
```bash
APP_VERSION=1.0.0 BUILD_VERSION=1 ./build-app.sh
```

Outputs:
- `dist/Claude Switch.app`
- `dist/Claude Switch.zip`

GitHub Releases are expected to upload:
- `Claude Switch.zip`

## Persisted Data

The app uses persisted storage for:
- Claude usage snapshots by email
- Codex usage snapshot
- weekly reset overrides by Claude email
- OAuth credential cache for Claude
- app preferences via `@AppStorage`

## UI Conventions

Claude tab:
- configured accounts section
- expandable add-account section

Codex tab:
- single configured-account style section

Settings tab:
- compact settings rows with right-aligned small toggles

Account cards:
- active Claude account uses orange tint
- Codex uses blue tint
- numbered SF Symbols indicate account order

## Known Risks / Maintenance Notes

1. Menu bar popup height still needs care as managed accounts grow.
   Current approach constrains the list only after several accounts.

2. The top selector is custom UI.
   It is easier to style, but must be watched for accessibility and layout regressions.

3. GitHub updater depends on Releases being published correctly with the expected zip asset.

4. Claude usage normalization is a known footgun.
   If weekly usage suddenly jumps to `100%`, verify the normalization path first.

5. Auto-update should continue to avoid destructive replacement strategies.

## Recommended Agent Workflow

If you are an agent working on this repo:

1. Read:
   - `Sources/ClaudeSwitchMenuBar/ClaudeSwitchMenuBarApp.swift`
   - `Sources/ClaudeSwitchMenuBar/ClaudeUsage.swift`
   - `Sources/ClaudeSwitchMenuBar/CodexUsage.swift`
   - `Sources/ClaudeSwitchMenuBar/AppUpdater.swift`

2. Verify whether a change touches:
   - Claude switching
   - Claude usage normalization
   - Codex reset logic
   - updater/install logic
   - menu bar selector layout

3. After UI changes:
   - run `swift test`
   - run `./build-app.sh`
   - reinstall the app in `~/Applications`

4. When touching updater or release logic:
   - confirm the zip asset name remains exactly `Claude Switch.zip`

5. When touching Claude usage:
   - double-check that `1.0` is interpreted as `1%`, not `100%`

## Related Docs

- `README.md`
- `ThirdParty/cc-account-switcher/README.md`
- `ThirdParty/cc-account-switcher/LICENSE`
