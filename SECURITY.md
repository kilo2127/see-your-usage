# Data handling and public releases

The repository contains integration code and synthetic test fixtures, not a
ModelBest account or access grant. Deploying it does not grant access to the
internal platform. Users supply their own HTTPS origin and authenticate normally.

## Local data

- LLM Center origin: app preferences outside the repository.
- LLM Center login token: macOS Keychain, scoped to the configured origin.
- If Keychain is inaccessible, a fresh browser login may remain in process memory
  only. No keychain ACL changes, plaintext credential files, or token logging.
- Codex login: read locally from the user's existing auth file, without modification.
- Usage: held in memory. No analytics, remote collection, or request-log export.

LLM Center requests are limited to personal quota retrieval and the platform's
browser authorization flow. Redirects never forward bearer tokens. Authorization
pages must match the configured HTTPS origin. Server error bodies are not surfaced.

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
