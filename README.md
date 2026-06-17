# see-your-usage

Minimal, safe, low-energy macOS menu bar app for watching your Codex usage.

It shows the 5-hour and 7-day Codex windows directly in the menu bar, with a compact glassy dashboard on click. It is a native AppKit app: no Electron, no WebView, no background terminal, and no busy polling.

## Quick Start

```sh
git clone https://github.com/kilo2127/see-your-usage.git
cd see-your-usage
./scripts/run.sh
```

That builds the app, installs it to `~/Applications/see-your-usage.app`, and starts it. After that, Spotlight can find `see-your-usage`.

## Supported Macs

- macOS 14 or newer.
- Apple Silicon and Intel Macs.
- Requires Xcode Command Line Tools because this project builds from Swift source.

## Features

- Two-line menu bar display for `5h` and `7d`.
- Dot usage bars with green/yellow/red remaining-capacity color.
- Reset time/date shown beside each window.
- Glass-style popover dashboard with manual refresh and pause/resume.
- Open at Login toggle, enabled by default when running as an app bundle.
- Spotlight-friendly install into `~/Applications`.
- Low energy by design: native UI, 10-minute normal refresh cadence, timer tolerance, reset-aware refresh, and no timer while paused.

## Commands

```sh
./scripts/run.sh        # build, install, and open
./scripts/install_app.sh
./scripts/build_app.sh
swift test
```

## Safety

- Reads `~/.codex/auth.json` locally to use your existing Codex login.
- Does not modify `~/.codex/auth.json`.
- Does not store or print access tokens.
- Sends one read-only usage request to `https://chatgpt.com/backend-api/wham/usage`.
- Does not start, stop, inspect, or control Codex sessions.
- Build artifacts and generated icons are ignored by git.

## License

MIT
