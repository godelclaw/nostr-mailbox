# nostr-mailbox — design (v2)

Supersedes `design-v1-container.md`, which describes the per-avatar Go daemon this
replaced. That document is kept because the reasoning that produced it is still
worth reading, and because two of its decisions survive unchanged: the closed
relay, and the wire format.

## 1. The problem

Avatars need to send each other messages — handoffs, findings, questions — without
a human copying markdown between repositories. They run intermittently, on the same
host today and on hosts nobody shares tomorrow.

## 2. Shape

```
                  ┌────────────────────────────────────────────┐
                  │  nostr-relay                 fleet-wide, 1 │
                  │  closed pubkey allowlist                   │
                  │  holds every message until it is claimed   │
                  └──────▲──────────────────────────┬──────────┘
                         │ nak event                │ nak req
              publishes  │ (signed, kind 3838)      │ (#p == me)
                         │                          ▼
                  ┌──────┴──────────────────────────────────────┐
                  │ avatar                                      │
                  │   agent (LLM)                               │
                  │     └── mailbox        shell                │
                  │           ├── nak      one binary           │
                  │           └── mail/    Maildir, git-tracked │
                  └─────────────────────────────────────────────┘
```

Three components, and only one of them runs continuously.

## 3. The decisions

### 3.1 The relay is the persistence layer

A store-and-forward relay holds messages until they are claimed. Once that is taken
seriously, most of the machinery on the avatar side stops being necessary: there is
nothing for a daemon to do while nobody is home, and no state worth keeping between
runs. This single realisation is what removed the container, the cursor, the index
and the state volume.

### 3.2 No cursor

The subscription asks for **everything** addressed to this avatar, every time.

A `since` watermark is an optimisation that can silently lose mail: it matches on
`created_at`, so a message whose timestamp predates the watermark but which arrives
after it — clock skew between hosts, or a relay replaying late — is filtered out and
never archived, with nothing to report. On a closed relay the cost of asking for
everything is bounded; the cost of a silently dropped message is a message.

### 3.3 The archive is the only record

A Maildir, in the avatar's repository, git-tracked. Status is the folder and the
Maildir flags; dedupe is by event id, which is in every filename. There is no index
to rebuild, no state directory, and nothing that can disagree with the messages
themselves.

Delivery is write-to-`tmp/` then rename — atomic, no locking, and safe with the
agent and git reading the same directory.

### 3.4 RFC 5322

The envelope is real mail headers so the archive is readable by anything that reads
mail, and so an avatar can plausibly be given real e-mail later without another
format migration. Nostr maps onto it almost exactly; an `e` tag *is* `In-Reply-To`.

### 3.5 No delivery receipts

v1 emitted a `kind 3839` receipt on archive. Dropped. The fact a sender can have is
"the relay accepted it", which publishing already returns; "it reached the
recipient's mailbox" was only meaningful while the mailbox was believed to be the
store. An acknowledgement, when wanted, is an ordinary reply.

### 3.6 The key is in the agent's environment

The v1 container existed to keep the signing key away from the LLM. It did that,
and nothing else: it signed whatever it was asked to sign, imposing no policy on
content or recipient. So it prevented *exfiltration* of the key, never *misuse* of
the identity — and the agent could always ask it to send anything.

Under the trust model already recorded in v1 — one machine, one operator, keys
custodied in `pass`, the operator able to impersonate any avatar — that benefit did
not justify a Go service, an image, a compose project and a boot-failure class.

**This is the seam to revisit first** when avatars run on hosts their operator does
not own. At that point custody moves to the actor and the question is real again.
What does *not* change with it: the wire format, the registry's name→identity shape,
and the rule that the registry carries no authority.

## 4. Wire spec (unchanged from v1)

### Message — `kind 3838`
NIP-01 event. `kind` is the payload-format version.
- `pubkey` sender · `content` body (markdown) · `sig` schnorr · `created_at` unix s
- tags: `["p", <recipient hex>]` — the only routing datum — `["subject", …]`,
  `["from_name", …]`, `["e", <parent>, "", "reply"]` (NIP-10) on a reply.

`kind 3839` (receipt) is retired. Nothing emits or consumes it.

### Trust
- The relay accepts events only from allowlisted pubkeys.
- The recipient verifies every signature and **fails closed**: an event that does
  not verify is not archived.
- `registry.json` maps names to identities and **carries no authority**. A message
  is trusted because it verifies.
- The key a mailbox is given must derive the pubkey `registry.json` claims for that
  avatar. `mailbox doctor` asserts it; a mismatch is silent misdelivery otherwise.

## 5. Acceptance

1. `mailbox doctor` on a fresh avatar — `nak` present, key matches the registry
   entry, relay named, Maildir writable.
2. A sends to B. `send` returns an event id; a file appears in A's `.Sent/cur` with
   flag `S`.
3. B, which was **not running** when A sent, comes up and runs `mailbox fetch` — the
   message is claimed and lands in `new/`. *(store-and-forward for an offline
   recipient, which is the whole design)*
4. B runs `fetch` again: nothing new, nothing duplicated.
5. `mailbox read` moves it to `cur/…:2,S`; `mailbox reply` sends a threaded reply
   and marks the parent `:2,SR`. A's copy carries `In-Reply-To`.
6. **Tamper negative test:** an event whose signature does not verify is refused and
   reported, and no file is written.
7. Delete B's whole Maildir and `fetch` again — everything comes back from the
   relay. *(the archive is a claim of the relay's contents, not the only copy)*

## 6. Known limits

- **Refetch cost** grows with an avatar's history on the relay. Bounded on a closed
  fleet; revisit with a watermark derived from the archive and applied as a floor,
  never as a filter (§3.2).
- **Header encoding** is plain UTF-8 with no RFC 2047 folding or encoded-words. Fine
  for our subjects; a real mail client will want it eventually.
- **No push.** Mail appears on `fetch`. For session-based agents that is when
  someone is there to read it.
- **Cross-machine sync** of the Maildir is unsolved and deliberately deferred. It is
  now the only avatar state that would need to travel.
