# Claude Switch

Native macOS menu bar app for managing `cc-account-switcher` with a friendlier UI.

It lets you:
- switch between saved Claude Code accounts
- add the current Claude account or connect another one through browser login
- optionally restart Claude Code automatically after switching
- track weekly Claude usage with pace indicators
- track Codex weekly/session usage in a separate tab
- choose whether the menu bar donut shows Claude Code or Codex usage

## Requirements

- macOS 13+
- Swift 6 toolchain
- [`cc-account-switcher`](https://github.com/ming86/cc-account-switcher) installed
- Claude Code installed for account switching
- Codex installed and authenticated if you want Codex usage tracking

## Development

Run the app in debug:

```bash
swift run ClaudeSwitchMenuBar
```

Build the `.app` bundle:

```bash
./build-app.sh
```

The generated app bundle is written to:

```bash
dist/Claude Switch.app
```

## How It Works

### Claude

The app reads the current Claude login, integrates with `ccswitch.sh`, and stores managed account state locally. Usage is refreshed periodically and also updated around account switches so the active account stays in sync.

### Codex

The Codex tab reads the local Codex auth/session files, refreshes tokens when needed, and requests usage from the Codex backend so you can track weekly and session consumption without switching accounts inside this app.

## Project Structure

- `Sources/ClaudeSwitchMenuBar/ClaudeSwitchMenuBarApp.swift`: menu bar UI, tabs, switching flow, app state
- `Sources/ClaudeSwitchMenuBar/ClaudeUsage.swift`: Claude usage models, pace logic, reset override storage
- `Sources/ClaudeSwitchMenuBar/CodexUsage.swift`: Codex usage models, auth refresh, usage fetching
- `build-app.sh`: release build script that assembles the macOS app bundle

## References

These were the main references used while building this project:

- [`ming86/cc-account-switcher`](https://github.com/ming86/cc-account-switcher): underlying Claude account switching workflow and shell integration
- [`steipete/CodexBar`](https://github.com/steipete/CodexBar): reference for Codex usage fetching, token refresh flow, and menu bar monitoring ideas

## Notes

- Claude weekly reset can be detected automatically, with a manual per-account override available in Settings.
- Codex usage is read-only in this app. It does not switch Codex accounts.
- The menu bar chart is intended as a quick weekly usage glance, while the window contains the more detailed breakdown.
