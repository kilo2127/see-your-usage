# see-your-usage

A native, low-energy macOS menu bar app for Codex and an optional LLM Center.
The two services are displayed and refreshed independently in one process.

## Preview

Product illustrations with example data and simplified controls.

<img src="docs/images/codex-illustration.png" width="760" alt="Codex illustration: compact menu bar indicator and weekly remaining quota">

<img src="docs/images/llm-center-illustration.png" width="760" alt="LLM Center illustration: right-aligned menu bar amounts, with today's spending above monthly remaining in the popover">

## Menu bar

- **Codex** keeps its segmented remaining-capacity bars and reset dates. Menu width
  follows the date text, with no window labels or refresh dot. Weekly-only responses
  use one row; full window names remain in the popover.
- **LLM Center** uses two unlabeled rows: personal monthly remaining amount above,
  today's spending below. Width follows the text instead of reserving a wide slot.
- Money uses `¥`: monthly amounts are integers and today's spending has one decimal,
  truncated rather than rounded. Actual zero spending today
  displays `Nah`. Large menu values use `万`; the popover shows the full integer.
- LLM Center monthly remaining amounts below 3,000 turn yellow; below 1,000 turn red.
  At 3,000 the color is green; at 1,000 it is yellow. These are the same system colors
  used by Codex. Codex's percentage thresholds are unchanged.

In the expanded LLM Center popover, today's usage is shown above monthly remaining.

## Independent service settings

Each popover has **启动并在菜单栏显示** and **开机启动此服务** switches.
Hiding a service stops its timers, requests and authorization polling. The other
service continues normally. Login startup preferences are independent; a manual
launch can still display a service whose login startup is off.

Use **服务…** in either popover to restore a hidden service. If both are hidden,
reopen `see-your-usage` from Spotlight or Applications to access these switches.
macOS lists one login item for the app; it runs the services enabled for login.

## LLM Center setup

LLM Center is an optional integration for ModelBest's internal API-key and budget
platform. It requires authorized company-network access. The implementation reads
personal quota data; it does not obtain inference API keys or perform model calls.

In its popover, choose **平台地址…** and enter the HTTPS root URL supplied by your
organization. The hostname is stored only in local app preferences, not in this
repository. An unconfigured installation makes no requests to an internal platform.

On launch, configured instances try saved credentials first. Missing login opens
browser authorization once. Connection failures show **登录 / LLM Center** in the
menu; configure or sign in through the popover as needed. No CLI is required.

Login tokens are stored in macOS Keychain and separated by platform origin.
Changing the platform address cancels existing requests and requires that origin's
login. The app rejects API redirects and authorization URLs on another origin.
Keychain operations prohibit system authentication prompts. Tokens are cached in
memory; denied keychain access stops retrying. If a new login cannot be persisted,
the app uses it in memory and explains that restart will require another login.
It never loosens keychain permissions or falls back to plaintext token files.

## Energy and freshness

- AppKit; no Electron, embedded browser, helper process, telemetry or CLI subprocess.
- One read-only LLM Center request per refresh; no log scanning or cost estimation.
- One coalescible, one-shot timer per running service: 5 minutes normally,
  10 minutes in Low Power Mode. No high-frequency UI timers or animation loops.
- Popover refreshes are deduplicated and throttled. Failures back off through
  5, 10, 20, 40, then 60 minutes. Manual refresh is throttled to 5 seconds.
- Pause, sleep or disabling the service cancels its work. Missing login/configuration
  stops periodic refresh. Wake schedules a delayed refresh instead of a burst.
- Beijing day/month boundaries invalidate old values when the display updates;
  last known data remains inside the popover with its timestamp and error.
- Authorization polling exists only during a bounded browser login attempt.

## Build and install

Requires macOS 14+ and Xcode Command Line Tools. Apple Silicon and Intel supported.

```sh
./scripts/run.sh
./scripts/build_app.sh
swift test
```

`run.sh` installs to `~/Applications/see-your-usage.app`. For native light/dark
layout snapshots using synthetic test fixtures:

```sh
SEE_USAGE_QA_DIR="$PWD/.build/qa" swift test
```

The README illustrations are drawn in
[HTML/CSS](docs/design/product-previews.html). To regenerate the separate native
UI captures from synthetic state:

```sh
SEE_USAGE_PRODUCT_DIR="$PWD/docs/images" swift test --filter renderProductScreenshots
```

Review [SECURITY.md](SECURITY.md) before publishing diagnostics or screenshots.

## License

MIT
