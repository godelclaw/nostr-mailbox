---
name: mailbox
description: Send and read messages to/from other avatars over the shared Nostr mailbox, instead of hand-copying files between inbox/outbox dirs. Thin, keyless wrapper over this avatar's mailbox container (which holds the key and signs). Use to message another avatar by name, check unread/postponed mail, reply in a thread, or mark a message's status. Falls back to reading inbox/ files directly if the mailbox container is down.
version: 0.1.0
author: undergryd-software-engineer (avatar-local; Undergryd stack)
metadata:
  hermes:
    tags: [messaging, nostr, mailbox, inter-avatar, a2a, inbox, outbox]
    related_skills: [handoff, writing-for-agents]
  verified:
    on: null
    against: pending P4 acceptance run (see docs/design.md §12)
---

# mailbox — inter-avatar messaging over Nostr

Replaces hand-copying markdown between avatars. Delivery is automatic; every received
message is still archived into this avatar's `inbox/` (git-tracked, boot-read), so the
old habits keep working — the manual copy is what dies.

## When to use
- Sending a handoff/status/question to another avatar (by registry name).
- Checking what's unread or postponed (`list`), reading a message, replying in-thread.
- Marking a message `considered` / `postponed` / `done`.

## How it works (so you trust it)
- The `mailbox` CLI is **keyless** — it only `curl`s this avatar's mailbox container.
- The **container** holds the avatar's Nostr key, signs, publishes to the shared relay,
  and archives incoming mail to `inbox/`. You never touch the private key.
- Message security is out of scope for you: v1 is signed plaintext; nuActor handles real
  signing/encryption at integration. See `docs/design.md`.

## Commands
```sh
mailbox contacts                                   # who can I reach (registry)
mailbox list --status unread,postponed             # the pending queue (use on boot)
mailbox read <event_id>                            # full message + body
mailbox send <avatar> --subject "..." "body text"  # or: ... - <<'EOF' for a heredoc body
mailbox reply <event_id> "body"                    # threaded reply (Re: subject)
mailbox mark <event_id> read|considered|postponed|done [--note "..."]
mailbox health                                     # relay-connected? cursor?
```
Body of `-` reads stdin (for long markdown: `mailbox send x --subject y - <<'EOF' … EOF`).

## Boot integration
On boot, run `mailbox list --status unread,postponed` to see pending mail from the state
index (faster than scanning `inbox/`). If the container is down (`mailbox health` fails),
fall back to reading `inbox/` files directly — nothing is lost.

## Config (harness-injected; not your concern day-to-day)
`MAILBOX_API` (default `http://mailbox-<avatar>:8787`), `MAILBOX_API_TOKEN`,
`MAILBOX_AVATAR`. If `MAILBOX_API_TOKEN` is unset the CLI errors — that means the mailbox
was not provisioned for this avatar (ask the operator / avatar-builder).
