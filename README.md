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

- macOS 15+
- Swift 6 toolchain
- Claude Code installed for account switching
- Codex installed and authenticated if you want Codex usage tracking

The repository vendors `cc-account-switcher` directly, so you do not need to install it separately for the app to work.

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

### Adding More Claude Accounts

To add another Claude Code account in the app:

1. Open the `Claude` tab.
2. Expand `Add Another Account`.
3. If the account you want is already the one currently signed in to Claude Code, click `Add Current Account`.
4. If you want to add a different account:
   - click `Log Out`
   - click `Browser Login`
   - complete the Claude login flow in the browser
   - return to the app
5. The newly authenticated account is saved and appears under `Configured Accounts`.

After that, you can switch back and forth between saved Claude accounts directly from the app.

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

The vendored switcher files live in `ThirdParty/cc-account-switcher/` with the original license included.

## Notes

- Claude weekly reset can be detected automatically, with a manual per-account override available in Settings.
- Codex usage is read-only in this app. It does not switch Codex accounts.
- The menu bar chart is intended as a quick weekly usage glance, while the window contains the more detailed breakdown.
