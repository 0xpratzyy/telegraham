# Security and privacy

Never include secrets or private conversation data in a public issue. For a
vulnerability, use the repository's private vulnerability-reporting feature
when enabled, or contact the maintainer through their GitHub profile to request
a private channel before sending details.

Pidgy stores imported messages on this Mac. When an AI provider is enabled,
the context needed for that feature is sent to that provider. The README lists
network destinations. Local-first storage does not mean AI inference is offline.

ChatGPT plan access is optional. Pidgy uses the documented public-client OAuth
flow, validates the signed ID token, and keeps tokens in the macOS Keychain in
Release builds. Debug/test credential files use owner-only permissions.
Background fact extraction on this provider is off until explicitly enabled.
Sign-out attempts remote session revocation and clears local tokens; if remote
revocation fails, Pidgy directs users to disconnect the app in ChatGPT settings.

Local config files, caches, databases, evaluation snapshots, and distribution
artifacts must stay outside public source archives. `scripts/prepare_open_source.py`
creates a fresh, audited source snapshot without the private Git history.
Making an existing repository public exposes its entire reachable history;
an archive audit is not authorization to publish that history.
