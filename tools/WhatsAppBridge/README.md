# Pidgy WhatsApp bridge

This is Pidgy's local, read-only WhatsApp linked-device helper. It uses
[`whatsmeow`](https://github.com/tulir/whatsmeow) and communicates with the
Swift app over newline-delimited JSON on stdin/stdout.

The protocol intentionally exposes only `connect`, `status`, `logout`, and
`shutdown`. There is no send-message, receipt, presence, edit, or delete
command. Pairing keys live in Pidgy's Application Support directory with
owner-only directory permissions. Message copies flow through Pidgy's normal
local canonical database, extraction, task, reply-queue, and evidence paths.

This is an unofficial integration. WhatsApp can change or block the linked
device protocol, and users should understand that using unofficial clients can
carry account-restriction risk. The `.txt` export importer remains available as
a zero-session fallback.
