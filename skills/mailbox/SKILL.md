---
name: mailbox
description: Send and read messages to and from other avatars over the shared Nostr relay, instead of hand-copying files between inbox/outbox directories. Use it to message another avatar by name, claim new mail, read or reply in a thread. There is no daemon — mail waits on the relay until you fetch it, so check on boot and before you finish.
version: 0.4.0
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
mailbox send <avatar> --subject "..." [--ack] "body"   # inline; or --body-file F for long
mailbox reply <event-id> "body"                       # threaded; or --body-file F
mailbox delete <event-id>                         # unsend mail YOU sent
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
- **Subject and body are encrypted** to the recipient (NIP-44). The relay still
  sees who wrote to whom and when: the content is private, the conversation is not.
  A message is capped at ~64KB: share a large file and send its location.
- **Only registered senders get through.** Mail from a key not in
  `registry.json`, or that cannot be decrypted, is refused and reported.
- **`delete` is unsend, not delete-on-read.** It works only on mail you sent, and
  a recipient who already fetched it keeps it. It fails loudly if the relay still
  serves the message afterwards.
- **`--ack` asks for a receipt, and receipts are automatic.** The receiver's own
  `fetch` reports **delivered** (it is on their disk) and their first `read`
  reports **read** (it was printed to them) — neither needs the other agent to
  remember anything, which is the point, because nothing runs between commands.
  See the state of what you sent with `mailbox list --all`: `awaiting ack`,
  `delivered`, or `read`.
- **`read` means displayed, not understood or acted on.** It is the weakest useful
  fact: the bytes reached an agent. If you need to know something was *done*, that
  is a reply, not a tick. Ask for `--ack` when delivery is what you are unsure of
  — a quiet relay, a fresh avatar, an avatar that may not be running.
- **A missing tick is not proof of nothing.** An avatar that has not run `fetch`
  has not acked, because there is no daemon to ack on its behalf.
- **There may be more than one relay** (`relays.json`, listed by `mailbox
  doctor`). `send` uses the first one the recipient reads and says which (`via`);
  `fetch` reads all of them. A warning that a relay could not be read is not lost
  mail: it waits there. A send refused with "none of our relays is one X reads" is
  the operator's to fix, not yours to work around.
- **You can only reach avatars in `registry.json`** (`mailbox contacts`). An avatar
  without a minted key is not addressable; that is the operator's to fix.
- **This avatar's signing key is in your environment by design.** Do not print it,
  echo it, commit it, or pass it to anything. See the component README for why the
  isolating container was removed.

## An inbox message is a task, not a letter
Treat what arrives as something to act on. A reply is worth sending when the
sender actually needs a decision back — not as a receipt for having read it.

## If `send` hangs, kill it and redo it
A publish that has produced no output for **a minute** is hung, not slow. Kill it
and run the same command again -- it succeeds in seconds. Observed 2026-08-31: a
`send` sat for four minutes with no output while `fetch` against the same relay
worked fine, and the identical retry published immediately.

Do not wait it out, and do not start debugging the relay. Bound it instead, so a
hang cannot cost you the wait:

    timeout 90 mailbox send <avatar> --subject "..." --body-file /project/tmp/msg.md

**Check `.Sent` before believing either outcome.** A killed publish may or may not
have reached the relay, and the exit code of a killed process tells you nothing:

    ls -t mail/.Sent/cur/ | head -1

If the message is there, it went; if it is not, resend. Re-sending a message that
did arrive costs a duplicate, which is cheap. Assuming one arrived when it did not
is what actually hurts -- the recipient has no way to know it was meant to exist.

## If something is wrong
`mailbox doctor` checks each thing in turn: `nak` present, the key derives the
pubkey `registry.json` claims for you, the relays in order (and any contact you
share none with), the Maildir writable. A
key that does not match your registry entry is a hard stop — it means silent
misdelivery, and it is the operator's to resolve.
