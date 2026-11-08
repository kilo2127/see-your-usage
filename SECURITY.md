# Data handling and public releases

The repository contains integration code and synthetic test fixtures, not a
ModelBest account or access grant. Deploying it does not grant access to the
internal platform. Users supply their own HTTPS origin and authenticate normally.

## Local data

- LLM Center origin: app preferences outside the repository.
- LLM Center session: macOS Keychain, scoped to the configured origin. Access/refresh pairs
  are updated together on renewal. New PKCE logins use the `pkceSession@` account
  namespace and replace a session only after quota validation. Older OIDC and
  web-token entries remain readable when permitted by their existing ACLs. A legacy
  browser connection URL is stored in Keychain, not preferences.
- If Keychain is inaccessible, a fresh browser login may remain in process memory
  only. No keychain ACL changes, plaintext credential files, or token logging.
- Codex login: read locally from the user's existing auth file, without modification.
- Usage: held in memory. No analytics, remote collection, or request-log export.

LLM Center requests are limited to personal quota, project listings and quota details, current-account identity,
selected-project usage statistics, login and OIDC renewal. Member-based project
statistics are filtered by the current account, project and Beijing date. The
platform includes member key fields in project details; the decoder ignores them.
The app does not use, persist or log inference keys.
Login uses the platform's official session and polling API with PKCE (S256).
A 32-byte secure random verifier remains in memory; only its SHA-256 challenge is
sent when creating a session. Safari visits the returned OIDC authorization URL.
The platform relays a one-time code, which the app exchanges directly for access
and refresh tokens. The verifier, codes and tokens are never logged or written to
plaintext files. Native renewal does not need Safari or Automation permission.

The configured platform supplies the authorization metadata over HTTPS. The app
requires the authorization and token endpoints to share an HTTPS origin and the
callback to belong to the platform. It verifies state, client ID, callback,
response type and PKCE challenge before opening the browser or exchanging a code.
Native API, code exchange, discovery and renewal requests reject redirects.
These LLM Center requests use a direct connection through the company network,
without the system forward proxy; HTTPS certificate validation is unchanged.
The independent Codex connection continues to use system proxy settings.
A failed exchange or quota validation preserves the previously saved credentials.
Rotating refresh grants finish saving even when the caller cancels.

Legacy servers and web-token sessions retain the original browser recovery path.
Only this legacy explicit login can request Safari Automation permission.
Background legacy recovery creates a temporary tab in an existing window, without
selecting tabs, activating Safari, creating windows or requesting permission.
Cleanup closes only a single unselected tab matching the attempt's unique URL.
Selected, navigated or duplicated tabs remain untouched. URLs are structured Apple
event arguments. The app never injects JavaScript, changes Safari settings, or
reads browser cookies, passwords or refresh tokens. Polling stops at its deadline,
on success, failure or cancellation.

Login-event logs contain only lifecycle, safe failure categories and persistence
results, never URLs, authorization state, tokens or server error bodies. No issuer
or company hostname is embedded in the application or test fixtures.

## Before pushing or sharing

Keep real tokens, private keys, auth/config exports, HAR files, and application
logs out of Git. Ignore rules cover common local credential/diagnostic files, but
ignore rules do not remove data already tracked in Git or its history.

Use synthetic values in tests and screenshots. Screenshots of live dashboards can
reveal private budgets, usage, account details or internal hostnames. Inspect binary
assets manually before publishing them. If a credential was ever committed, revoke
it and clean the history before publication; deleting the current file is not enough.

The build uses ad-hoc local signing. A rebuilt executable can lose an earlier
Keychain item's trust. The app suppresses authentication dialogs and requests a fresh
browser login instead; it does not bypass macOS Keychain protections.
Every native Keychain read or write disables legacy login-keychain interaction
with `SecKeychainSetUserInteractionAllowed(false)` as well as using a noninteractive
`LAContext`. Failure to apply this policy stops the operation. The app never
re-enables interactive Keychain access.
