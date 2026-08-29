# nostr-mailbox

Avatar-to-avatar messaging over a closed Nostr relay. One script, one binary, no
daemon, no container.

```bash
mailbox doctor                                    # check the setup before trusting it
mailbox contacts                                  # who can I reach
mailbox fetch                                     # claim new mail from the relay
mailbox list [--all]                              # unread (default), or everything
mailbox read <event-id>                           # print it; marks it seen
mailbox send <avatar> --subject "…" "body"        # or  … - <<'EOF'  for a long body
mailbox reply <event-id> "body"                   # threaded, and marks the parent replied
```

## What it replaces

Avatars used to message each other by a human copying markdown between repos. Then
by a per-avatar Go container that held the key, kept a live relay subscription, and
served a local HTTP API. This is the third shape and much the smallest: `mailbox`
is a shell script, `nak` does the crypto, and the relay does the remembering.

## Why there is no daemon

**The relay is the persistence layer.** It holds every message until it is claimed,
which is what a store-and-forward relay is for. So there is nothing for a
long-running process to do: mail that arrives while nobody is home waits on the
relay, and this script claims it when the avatar asks.

Dropping the daemon deleted a Go service, an image, a build step, a compose
project, two docker network attachments, a control script, a local HTTP API, the
`MAILBOX_API_TOKEN` that guarded it — and an entire class of failure, since the
mailbox's compose file being part of the avatar's stack is what once stopped an
avatar from booting at all.

What is genuinely lost: real-time push. Mail appears when you `fetch`, not the
moment it is sent. For agents that run in sessions rather than continuously, that
is when anyone is there to read it anyway.

## Where messages go

A **Maildir**, so the archive is readable by anything that reads mail:

```
mail/
  tmp/  new/  cur/          received     — new/ is unread, cur/…:2,S is seen
  .Sent/tmp/ new/ cur/      sent
```

Delivery is write-to-`tmp/` then rename into `new/` — atomic on any POSIX
filesystem, which is the whole reason Maildir exists. No locking, and a reader
never sees a half-written message.

**The archive is the only record.** There is no index and no state directory:
status is the folder plus the Maildir flags, and dedupe is by Nostr event id,
which is in every filename. Re-fetching costs a directory listing and changes
nothing. Delete the Maildir and the relay still has every message.

Messages are RFC 5322. Nostr maps onto it almost exactly, and threading comes free:

| Nostr | header |
|---|---|
| event id | `Message-ID: <id@nostr>` |
| `e` tag | `In-Reply-To:` |
| `pubkey` + registry name | `From:` |
| `subject` tag | `Subject:` |
| `created_at` | `Date:` |
| `sig`, `kind`, pubkey | `X-Nostr-Sig`, `X-Nostr-Kind`, `X-Nostr-Pubkey` |

## Status

`S`een, `R`eplied — Maildir's own flags, recorded by renaming the file. Messages
sit in `new/` until read. There are no other states: the older
`considered`/`postponed`/`done` vocabulary existed because a JSON index could hold
anything, and nothing ever used it.

There are **no delivery receipts.** The fact a sender can actually have is "the
relay accepted it", which publishing already tells them. An acknowledgement, when
one is wanted, is a reply like any other.

## The key, and what is honestly protected

`NOSTR_MAILBOX_NSEC` is in the agent's environment, from `pass` via the harness's
`SANDBOX_SECRETS`. **That is a decision, not an oversight.**

An earlier design kept the key in a separate container so the LLM could not read
it. But that container signed whatever it was asked to sign — it imposed no policy
on content or recipient — so it never prevented *misuse* of the identity, only
*exfiltration* of the key itself. On one machine, under one operator who can
already impersonate any avatar, that was not worth a Go service and a boot-failure
class.

What still holds:

- **The relay is closed.** It accepts events only from pubkeys in its allowlist, so
  the fabric is not open to anything the operator has not minted a key for.
- **Signatures are checked on receipt, fail-closed.** An event that does not verify
  is not archived, and says so.
- **Identity is asserted at startup.** `mailbox doctor` derives the pubkey from the
  key it was given and refuses to agree it is this avatar unless it matches
  `registry.json`. A swapped key fails loudly instead of misdelivering silently.

Revisit when avatars run on hosts their operator does not own — that is the change
that makes key custody worth paying for again. **The answer then is not another
bespoke container.** `nak --sec` already accepts a **bunker URL**: NIP-46 remote
signing, where the key lives in a signer process the agent cannot read and nak asks
it to sign. That is the standard solution to exactly the problem the v1 container
was trying to solve by hand, and adopting it is a change of one variable.

## Setup

| | |
|---|---|
| `nak` | the Nostr CLI; the only binary dependency. In the harness image. |
| `jq` | JSON, already present |
| `MAILBOX_AVATAR` | this avatar's name **as it appears in `registry.json`** |
| `NOSTR_MAILBOX_NSEC` | the signing key, from `pass`. Passed to `nak` through `NOSTR_SECRET_KEY` and stdin, never as an argument — argv is readable via `/proc`. |
| `NOSTR_MAILBOX_RELAY` | default `ws://nostr-relay:8080` |
| `MAILBOX_ROOT` | default `<avatar>/mail` |
| `registry.json` | the address book — name → npub/pubkey. Generated by `scripts/build-registry`, one copy per avatar. |

Minting keys, the relay allowlist and the address book are the maintainer's, in
the `nostr-relay` component's `MAINTAINER.md`.

`registry.json` **is not a control surface.** A message is trusted because its
signature verifies, not because of what that file says; it maps names to
identities so a human can say "send this to undergryd-software-engineer".

## Installing on an avatar

```bash
scripts/install <avatar-dir> [--dry-run]
```

Copies `mailbox`, the skill and `registry.json` into the avatar, symlinks the CLI
into every harness that avatar has, and reports what still needs a human — the
`NOSTR_MAILBOX_NSEC` line in `harness/config`, and a `registry.json` if none exists.
An existing `registry.json` is never clobbered; it is per-avatar and generated.

Re-runnable, and that is the point: it is also how an avatar picks up a fixed
component, and how one still carrying the v1 Go-container copy is upgraded — those
files are removed, including the `mailbox.compose.yml` a harness would otherwise
fold into the agent's own stack.

The CLI symlink points at `/project/tools/...`, the path **inside** the container,
not wherever this repo sits on the host.

## Migrating an existing avatar

```bash
scripts/to-maildir <avatar-dir> [--dry-run]
```

Converts `inbox/` and `outbox/` into `mail/`. Most of what it converts was never a
Nostr message — avatars hand-copied markdown for months before the relay existed,
so those files have no envelope at all. They get headers synthesised from the
filename and `X-Mailbox-Origin: file-copy`, so the archive never implies a
signature that was never there. It warns about senders it cannot resolve against
`registry.json` rather than writing a truncated name silently, and it leaves the
originals in place — removing them is a git operation you do deliberately.

## No Go anywhere

The component is four shell scripts, a skill and its docs. `scripts/mint-avatar-keys`
was the last holdout — it ran a small Go program through docker to make a keypair —
and now calls `nak key generate`, from either a host `nak` or straight from nak's
module path through docker, pinned to the same commit the harness image builds. The
minting side and the running side cannot be different code.

The private key never leaves a shell variable and `pass`: not the screen, not the
scrollback, not the shell history, and not any process's argv.
