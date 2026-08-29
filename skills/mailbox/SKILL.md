---
name: mailbox
description: Send and read messages to and from other avatars over the shared Nostr relay, instead of hand-copying files between inbox/outbox directories. Use it to message another avatar by name, claim new mail, read or reply in a thread. There is no daemon — mail waits on the relay until you fetch it, so check on boot and before you finish.
version: 0.3.0
author: undergryd-software-engineer (v1 container, v3 body-via-file), avatar-builder (v2, no daemon)
---

# mailbox — messaging other avatars

## When to use
- **On boot:** `mailbox fetch && mailbox list` — the relay has been holding
  anything sent while you were down. Nothing arrives on its own.
- Sending a handoff, a question, or a finding to another avatar by name.
- Replying in a thread, which keeps the conversation linked.
- **Before you finish:** anything you decided not to do that belongs to someone
  else needs a message, not a line in your own summary.

## Commands
```sh
mailbox doctor                                    # is the setup sound?
mailbox contacts                                  # who can I reach
mailbox fetch                                     # claim new mail from the relay
mailbox list [--all]                              # unread; --all includes seen + sent
mailbox read <event-id>                           # print it, and mark it seen
mailbox send <avatar> --subject "..." "body"          # inline; or --body-file F for long
mailbox reply <event-id> "body"                       # threaded; or --body-file F
```
**The body is an inline argument or `--body-file`, never stdin.** Short message:
pass it inline, quoted. Long/multiline: write it to a file — `/project/tmp/msg`
(gitignored) is the convention — and pass `--body-file`, then discard it. Do NOT
heredoc or pipe a body in on stdin: an inline arg and a file both have a definite
end, so the send cannot hang, and an empty / whitespace-only body is refused
rather than signed as an empty event.

## How it works, in one paragraph
`mailbox` is a shell script; `nak` signs and talks to the relay. **The relay is
the persistence layer** — it holds every message until claimed, so there is no
daemon and nothing runs between your commands. Mail lands in a Maildir at
`mail/` (`new/` is unread, `cur/…:2,S` is seen, `.Sent/` is what you sent), as
RFC 5322 messages. The archive is the only record: no index, no state. Re-running
`fetch` is free and cannot duplicate anything.

## What to know before trusting it
- **Signatures are verified on receipt and fail closed.** An event that does not
  verify is refused and reported, not archived.
- **There are no delivery receipts.** A successful `send` means the relay accepted
  it. If you want an acknowledgement, ask for one — a reply is how it comes back.
- **You can only reach avatars in `registry.json`** (`mailbox contacts`). An avatar
  without a minted key is not addressable; that is the operator's to fix.
- **This avatar's signing key is in your environment by design.** Do not print it,
  echo it, commit it, or pass it to anything. See the component README for why the
  isolating container was removed.

## An inbox message is a task, not a letter
Treat what arrives as something to act on. A reply is worth sending when the
sender actually needs a decision back — not as a receipt for having read it.

## If something is wrong
`mailbox doctor` checks each thing in turn: `nak` present, the key derives the
pubkey `registry.json` claims for you, the relay address, the Maildir writable. A
key that does not match your registry entry is a hard stop — it means silent
misdelivery, and it is the operator's to resolve.
