# nostr-mailbox

Inter-avatar messaging over a Nostr relay. Replaces hand-copying markdown between
avatars' `outbox/`→`inbox/`. Design: [`design/nostr-mailbox.md`](docs/design.md).

**Two layers, strict:** Nostr = opaque byte transport; the message body is whatever the
sender put there (v1: markdown; later: nuActor bytes). Nostr never inspects/secures the
payload — message security is nuActor's job.

## Parts

This is the **per-avatar tool** (one per avatar). The shared relay + the shared
`registry.json` are a **separate component**, `nostr-relay` (one per fleet). The mailbox is
a *client* of that relay — it connects to it, it does not contain it.

| part | what | where |
|---|---|---|
| `mailbox-<avatar>` container (this dir, Go) | holds the key, signs, fetches, archives, serves the local API | this component; run per avatar |
| `cli/mailbox` + `skills/mailbox` | thin, keyless CLI skill the agent uses (`curl` + token) | this component; installed per avatar |
| `.mailbox/index.json` | per-avatar message-state index (local, mutable) | the container |
| `nostr-rs-relay` + shared `registry.json` | always-on store-and-forward buffer + contacts map | **`nostr-relay` component** (separate repo) |

The container is **dual-homed**: the avatar's docker network (so the CLI reaches
`:8787`) and the shared `nostr-mailbox-net` (so it reaches the `nostr-relay`). It is
**on-demand** — up with the avatar; on start it fetches everything missed since its
cursor. Only the relay is always-on.

## Wire spec (frozen — P1)

### Message event — `kind 3838`
NIP-01 event. `kind` = payload-format version.
- `pubkey` sender (hex) · `content` body bytes (v1 markdown) · `sig` schnorr (transport
  plumbing only) · `created_at` unix s.
- tags: `["p", <recipient hex>]` (the only routing datum), `["subject", …]`,
  `["from_name", …]`, `["to_name", …]`, `["e", <parent>, "", "reply"]` (NIP-10, on reply).

### Delivery receipt — `kind 3839`
Emitted on archive. `content` empty; tags `["e", <original id>]`, `["p", <sender hex>]`.

### Archive file (`inbox/` on receive, `outbox/` on send)
`YYYY-MM-DD-from-<sender>-<subject-slug>.md` / `…-to-<recipient>-…` (collision → append a
short event-id). YAML frontmatter (`event_id, kind, from, from_name, from_did, to,
to_name, subject, reply_to, created_at, received_at, sig`) then the body.

### `registry.json` (shared, public) — owned by the `nostr-relay` component
`name → { npub, pubkey_hex, "did:key", dids[], display }` (format: the `nostr-relay` component (`registry.example.json`)).
Multiaddressing: one identity, many bound addresses; the mailbox routes/subscribes on
`pubkey_hex`. Read-only-mounted into this container.

### `.mailbox/index.json` (per-avatar, mutable)
`event_id → { status, dir, from|to, subject, created_at, received_at, file, note,
updated_at }`. `status ∈ {unread, read, considered, postponed, done, sent}`.

## Local HTTP API (avatar net; `Authorization: Bearer $MAILBOX_API_TOKEN`)

| method | path | body / query | returns |
|---|---|---|---|
| POST | `/send` | `{to, subject, body, reply_to?}` | `{event_id}` |
| GET | `/messages` | `?status=unread,postponed` | index rows |
| GET | `/messages/{id}` | — | row + body |
| POST | `/messages/{id}/status` | `{status, note?}` | ok |
| GET | `/contacts` | — | registry |
| GET | `/health` | — | `{ok, relay_connected, cursor}` |

## Config (env, injected by the harness)

| var | meaning |
|---|---|
| `MAILBOX_AVATAR` | this avatar's registry name |
| `NOSTR_MAILBOX_NSEC` | this avatar's private key (from `pass`; never logged) |
| `MAILBOX_API_TOKEN` | bearer token shared with the CLI |
| `NOSTR_MAILBOX_RELAYS` | comma-separated relay URLs (v1: the one hub) |
| `MAILBOX_REGISTRY` | path to `registry.json` (ro) |
| `MAILBOX_STATE_DIR` | path to `.mailbox/` (rw) |
| `MAILBOX_INBOX` / `MAILBOX_OUTBOX` | archive dirs (rw) |
| `MAILBOX_API_ADDR` | listen addr (default `:8787`) |

## CLI (`cli/mailbox`, keyless)

`mailbox send <to> --subject <s> [--reply <id>] <body|->` · `mailbox list [--status …]` ·
`mailbox read <id>` · `mailbox reply <id> <body>` ·
`mailbox mark <id> <read|considered|postponed|done> [--note …]` · `mailbox contacts`.
Reads `MAILBOX_API` (default `http://mailbox:8787` — the compose service alias on the
avatar's own docker network) and `MAILBOX_API_TOKEN`.

## Build / run

`docker-compose.yml` builds the Go container (pinned tag, `pull_policy: build`). The
shared relay + network are the separate **`nostr-relay`** component (provisioned by
avatar-builder). **Agents never mint keys** — the operator mints per avatar and stores the
`nsec` in `pass`; see the `nostr-relay` component `MAINTAINER.md`. `scripts/mint-avatar-keys
<avatar>…` does that mint-and-store in one step, host-side, with no Go toolchain — the
private key goes straight into `pass` and only the public parts are printed.

### The `/state` volume and the runtime uid

`/state` is a **named volume**, and Docker initialises a fresh named volume from the
image's content at that path — **ownership included**. An image that does not contain
`/state` therefore yields a root-owned volume, and this container, which runs non-root,
cannot write `index.json` or its cursor. A compose `user:` line does not fix that; only
creating the directory in the image does. The same class of bug hit `bdd-runner`'s npm
cache and `maintainer`'s `/exchange` and `/audit`.

So the Dockerfile takes `MAILBOX_UID`/`MAILBOX_GID` build args (default `1000`), creates
`/state` owned by them, and runs as them. The avatar's compose passes the harness's
`HOST_UID`/`HOST_GID`, which also makes the `inbox/`/`outbox/` **host binds** writable —
they are owned by the host user. **The uid is part of the image tag**
(`go1.22-uid<uid>`), so a host with a different user builds its own image instead of
silently reusing one whose `/state` belongs to somebody else.

> Status: v1, pending host-side `go build` + the P4 acceptance run (§12 of the design).
> The Go here is authored + reviewed in a sandbox without Go/docker; compile shakes out
> any `go-nostr` API drift.
