# Changelog

## Unreleased

- Hardened `.gitignore` before GitHub upload review to exclude local environment files, signing materials, private xcconfig files, generated Vault indexes, logs, and packaged release artifacts.
- Added MoMo Open API cloud notepad sync for Vault vocabulary exports, with Keychain token storage, two-step remote diff confirmation, a separate cloud sync index, and append-only remote content merging.
- Added a read-only MoMo Open API connection test in Settings so users can verify the token and target notepad before syncing.
- Fixed MoMo notepad detail/create/update requests to preserve the `/open/api/...` path, changed the cloud sync index into advisory history instead of a pre-remote filter, and made notepad updates fail safe if required remote metadata is missing.
- Invalidated stale cloud sync previews when the target notepad title changes, rejected duplicate-title notepad matches, and kept cloud-specific result wording visible after a sync completes.
- Increased MoMo Open API request timeout to 60 seconds and added bounded retry with backoff for timeouts and transient 408/429/5xx responses.
- Changed MoMo cloud sync from title-matching to explicit notepad selection: the import view now refreshes a cloud notepad list, lets the user choose a specific target by ID, and uses the Settings title only when creating a new cloud notepad.
- Fixed MoMo cloud sync write-response decoding: create/update success responses do not include `content`, so the client now decodes write APIs as lightweight notepad metadata instead of failing after a successful remote write.
