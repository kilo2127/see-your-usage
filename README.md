# Mind Your Usage

A tiny native macOS menu bar app for watching Codex usage windows.

It reads `~/.codex/auth.json` without modifying it, calls the Codex usage endpoint, and renders the 5-hour and 7-day windows as a compact two-line status item.

## Run

```sh
swift run MindYourUsage
```

## Build the app bundle

```sh
./scripts/build_app.sh
open ".build/release/Mind Your Usage.app"
```

The app is intentionally lightweight: no WebView, no Electron, no polling loop while paused, and normal refreshes are scheduled with timer tolerance to avoid needless wakeups.
