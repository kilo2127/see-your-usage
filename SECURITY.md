# Data handling and public releases

The repository contains integration code and synthetic test fixtures, not a
ModelBest account or access grant. Deploying it does not grant access to the
internal platform. Users supply their own HTTPS origin and authenticate normally.

## Local data

- LLM Center origin: app preferences outside the repository.
- LLM Center session: macOS Keychain, scoped to the configured origin. Existing
  access/refresh pairs are updated together on renewal. New Safari authorizations
  replace that record with a browser-issued web token after quota validation.
  The linked authorization URL is stored in the same Keychain record, not preferences.
- If Keychain is inaccessible, a fresh browser login may remain in process memory
  only. No keychain ACL changes, plaintext credential files, or token logging.
- Codex login: read locally from the user's existing auth file, without modification.
- Usage: held in memory. No analytics, remote collection, or request-log export.

LLM Center requests are limited to personal quota retrieval, login and OIDC renewal.
Login uses the platform's official device-authorization session and polling API.
An explicit login can request macOS Automation permission to control Safari.
This OS permission is broader than one tab; the implementation restricts its
background actions to creating a temporary tab at a new same-origin authorization
URL in an existing Safari window. Cleanup only closes a single unselected tab
matching that attempt's unique authorization URL. User-selected, navigated or
duplicated pages are left untouched. It does not inject JavaScript,
enable Safari developer options, read cookies, passwords or browser refresh tokens,
select tabs, activate Safari or create windows during background recovery.
URLs are passed as structured Apple event arguments, never interpolated into
executable source. Browser error dictionaries are not logged because they may contain
URLs. The original authorization tab can be closed; background recovery depends
on the browser's SSO session, not that tab's sessionStorage. Revoking Automation
permission or expiry of SSO can require explicit login.
Only explicit login may request permission, launch Safari or select a tab.
Permission denial permits a one-time login via Launch Services. Polling is bounded
by the authorization deadline and stops on completion, cancellation or failure.

Previously saved OIDC sessions retain native renewal, with an HTTPS token endpoint
on the issuer's origin. New device-flow web tokens have no documented renewal grant;
linked sessions recover through the official webpage, whose OIDC client owns renewal.
Native API, discovery and renewal requests reject redirects. Login-event logs contain
only the action source, lifecycle and persistence result, never URLs, authorization
state, tokens or server error bodies. No issuer or company hostname is embedded in
the application or test fixtures.

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
