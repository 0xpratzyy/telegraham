# Contributing to Pidgy

Pidgy is a native macOS app. Start with the source-build instructions in
[README.md](README.md). `project.yml` is the source of truth for the Xcode
project; regenerate with `xcodegen generate` after adding files.

Keep changes focused, describe the behavior they change, and include the
validation you ran. Preserve existing local changes when working in a shared
checkout. Add regression coverage for behavior fixes; mock network providers
and use temporary databases and credential directories.

Run `./scripts/test.sh` for the offline routing checks, Python tests, WhatsApp
bridge checks, and complete macOS XCTest suite. Live AI benchmarks are explicitly
opt-in and spend the configured account's allowance or API credits. Don't turn
them on in CI.

Do not submit messages, screenshots containing conversations, credentials,
databases, local traces, or benchmark snapshots. Use synthetic fixtures. Run
`bash scripts/scan_secrets.sh` before proposing a change. See
[SECURITY.md](SECURITY.md) for vulnerability reporting.

Changes to dependencies must update `Package.resolved` or `go.sum`, as
appropriate. Preserve third-party notices. Signing, notarization, update
publishing, and managed-service deployments require maintainer credentials;
they are separate from building or testing the open-source app.
