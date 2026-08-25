# Nostr Mailbox — design grilling (working doc)

Interactive inter-avatar messaging to replace manual file-copy between avatars.
Grounded in the colleague thread (Nostr-as-mailbox + nuActor migration) and the
NuNet `actor`/`did` source. This file is the live grilling record — answer the
Round 1 questions in your other window, tell me your picks here, and I recompute
the frontier.

Answer format: for each question, write `A`, `B`, (or `C`), or an amendment.
Accepting my recommendation = just say "ok Qn" or "➡️".

---

## Design frame (settled — the root of the tree)

From your task + the colleague discussion + the nuActor source, these are fixed
and NOT up for grilling:

- **Nostr *semantics*** (secp256k1-signed store-and-forward events, kinds, tags,
  mailbox subscriptions) are the avatar mailbox. Mail is async — recipient may be
  offline — which is exactly the relay store-and-forward model. (The colleague
  explicitly ruled *out* Nostr for the actor hot-path; mailbox is where it fits.)
- **Decouple semantics from transport.** Signed-event semantics are the value;
  raw WSS is a swappable transport (libp2p-stream later on NuNet). The tool's
  envelope + client code must be transport-agnostic.
- **One canonical identity** — reconcile the secp256k1 Nostr key with a DID so a
  node's npub and DID are not two separate identities.
Kabir: i do not thing this is a problem -- we already have bunch of addresses in actor idenity, like peer address, did, blabla; while reconcilation is desired, often in real world we have to adapt;
- **Internal addressing keyed off identity** (npub/DID); DDNS is an *external
  bridge* concern only — internal traffic never touches it.
Kabir: even for external stuff, i am thinking in the future to use wireguard vpn and some internal addressing schemes, probably based on dids, etc.
- **Encryption is our choice** internally (closed trusted set). Relays are
  best-effort; acks/retries are a layer we add only if we need at-least-once.
Kabir: i would like to have encryption;
- **nuActor is the migration target.** Actor's ID *is* its pubkey; it shares a
  DID; messages are signed `Envelope{To,From: Handle{ID,DID,Address}, Behavior,
  Message, Capability, Signature}`. Our envelope should foreshadow this so the
  eventual move is transport-only.
Kabir: yes, but the alidnment with actor model is the key here;
Btw, you may want to check nostr repo; if you need it locally, just let operator know or clone it yourself in /nunet-repos (if it is not yet cloned);

### Grounding facts (looked up, not assumed)

- Each avatar's tool containers sit on a **per-avatar docker network**
  (`${AGENT_NETWORK}`, e.g. `undergryd-software-engineer`) — isolated today. An
  "always-on mailbox all avatars reach" therefore needs a **shared** network/host
  endpoint every avatar joins = genuinely cross-avatar infra (avatar-builder's
  domain, like the shared parts of the QA stack).
- `nuActor` (DMS `actor/interface.go`, `actor/README.md`): pubkey = actor ID;
  process shares one DID (root actor's); `Handle{ID,DID,Address{HostID,
  InboxAddress}}`; capability tokens (UCAN) authorize each message; libp2p +
  gossipsub substrate today.
- DID machinery exists in `lib/did` (`did:key` embeds the pubkey directly —
  README: "Typically these are key DIDs, which embed the public key directly").
- No node/docker *inside* the sandbox, but the operator runs docker containers
  host-side per avatar via the `launch` harness (the QA stack proves this) — so
  an off-the-shelf relay image run host-side is feasible.
Kabir: note, that in nuActor we encapsulate containers into allocations -- which eventually can be OCI compliant miroVMs etc.
---

## ROUND 1 — the four independent branches off the root

Nothing downstream (relay impl, key custody, envelope schema, delivery/acks,
address registry, nuActor field-mapping, provisioning) can be pinned until these
four are answered.

### Q1 — Relay topology (the "always-on locally" shape)

- **(a)** One shared always-on relay container on a shared host network; every
  avatar sandbox connects to it as a client — a **hub**.
- **(b)** One embedded relay per avatar, federating into a **mesh** (the literal
  "each NuNet node is a Nostr node" end-state).

➡️ **Recommend (a)** for local v1, with client/envelope code kept transport- and
topology-agnostic so the same avatars become clients-of-their-own-embedded-relay
on the NuNet mesh later. It's one moving part to keep alive independent of any
single avatar's lifecycle; matches how you described it. The mesh is the
*migration target*, not something that earns its complexity on one host.

**Your answer:** agreed; but the mesh is a good idea when we will get to nunet network, as it will provide true decentralization, where different agents will be able to share messages between them, etc.


### Q2 — Identity model (colleague's explicit open question: DID-keyed vs npub-per-mailbox)

- **(a)** One secp256k1 keypair per avatar → **npub is the mailbox address** AND
  we **derive a `did:key`** from it. One key → one npub → one DID; single
  canonical identity.
- **(b)** Separate npub per mailbox, distinct from the avatar's DID, with a
  mapping table.

➡️ **Recommend (a).** Directly answers "one canonical mapping so npub and DID
aren't two identities." Satisfies "avatars have DIDs — here too or a workaround"
with **no workaround**: `did:key` over the same secp256k1 pubkey *is* a valid DID
and mirrors nuActor (ID = pubkey, shared DID). When NuNet issues ledger/PRISM
DIDs later, add a mapping `did:key → did:nunet`; the mailbox address is unchanged.

**Your answer:** alright, sounds good, as long as we can generate dids independently (in the future) and map them all into single identity identification schema;

### Q3 — Content confidentiality (you said "whatever encryption we want")

- **(a)** Signed but **plaintext** content (every message authenticated by
  signature; body readable/greppable).
- **(b)** **NIP-44 encrypted** per-recipient from day one.
- **(c)** Our own envelope encryption.

➡️ **Recommend (a)** for v1, envelope structured so NIP-44 (or our own) drops in
later without changing addressing or the CLI. It's a closed set of our own
trusted relays/agents; payloads are markdown handoffs we *want* to read/debug;
today's inbox files are already all-readable in git. Authenticity (signature) is
the property that matters between avatars; confidentiality *from each other* is
not a v1 requirement. Revisit the moment a mailbox carries a secret or an
untrusted/external avatar joins.

**Your answer:** eee. now i am thinking; maybe no ecnryption locally is good? eventually, since nuActor is encrypted, i would like to use that one out of the box, without inventing a new bycicle... but this depends on if an dhow to integrate into nuActor at that point. note, that message passing in nuActor is the whole semantics, not just transport... it implements actor model of concurrent computation.


### Q4 — Relationship to today's `inbox/`–`outbox/` files

- **(a)** Nostr **fully replaces** the file-copy convention (mailbox lives only on
  the relay, read via the tool).
- **(b)** Nostr is the **transport**; the receiving side **auto-writes** each
  delivered message into the avatar's `inbox/` as markdown (today's filename
  convention). The manual *copy* dies, not the files.

➡️ **Recommend (b).** Smallest change that actually kills the tedium: sending
becomes `mailbox send`, delivery becomes automatic, but the durable, greppable,
git-tracked, boot-read artifact stays exactly where every boot sequence already
looks. A relay outage never loses history; an avatar without the tool can still
read its mail. Pure-relay (a) forces a rewrite of every boot.md and loses the git
trail for no local gain.

**Your answer:** hmm, ok, souonds good. but in the future, i wonder if it would be a better way to have a better mailbox for each actor, possibly integrating ims, mails, etc. for now it is ok, for the future we may want to have a better way than to copy files, etc.

---

## ROUND 1 — SETTLED

- **Q1 = (a) hub** for local v1; mesh is the NuNet-era true-decentralization target.
- **Q2 = (a)+adapt.** npub = canonical *mailbox* address; identity is a **mapping
  record** (à la actor `Handle{ID,DID,Address}`) that admits independently-generated
  DIDs later, mapped into one identity scheme. Reconciliation desired, not forced.
- **Q3 = REOPENED** → see R2-Q1 (the real axis is "no bespoke crypto we'll rip out
  for nuActor's").
- **Q4 = (b)** transport + auto-archive to `inbox/` for v1; richer per-actor mailbox
  (IMs/mail integration) is a future want.

**Load-bearing principle (new):** alignment with the **actor model** is the key.
nuActor message-passing is *semantics, not just transport* (actor model of concurrent
computation). So migration is "mailbox → actor envelopes/behaviors under capability
auth," and the **durable artifacts are the envelope schema + identity model**, not the
relay/transport (which nuActor's libp2p mesh replaces wholesale).

### New grounding facts (looked up this round)

- **No nostr repo cloned** in `/nunet-repos`; no go-nostr/python-nostr vendored.
- **Sandbox runtimes: only** `python3` 3.12, `jq`, `curl`, `openssl`, `git`, `glab`.
  No Go/Node/Rust/websocat. → the in-sandbox **CLI is Python**; Go/Rust relays can
  only run **host-side** in a container (host docker is proven by the QA stack).
- Consequence: relay + CLI are the **disposable** local adapter; invest instead in
  the envelope + registry (language-agnostic JSON that survives into Go/nuActor).

---

## ROUND 2 — the frontier unblocked by Round 1

Answer each with a letter / amendment. Envelope *concrete schema* is deliberately
held for Round 3 (it depends on R2-Q1 and R2-Q3 below).

### R2-Q1 — Encryption stance (the reopened Q3; "don't invent a bicycle")

Your worry: don't hand-roll crypto now that we discard when we adopt nuActor's
capability-based encrypted message-passing. Three honest positions:

- **(a) Plaintext + signature only** for v1. Real authenticity (every message
  signed, verifiable by npub), zero confidentiality. Adopt nuActor's encryption
  wholesale at integration. Least throwaway; but no encryption now (contra your
  "I would like to have encryption").
- **(b) NIP-44 encryption now.** NIP-44 is the *Nostr ecosystem standard* for
  encrypted DMs (a vetted library primitive, **not** a bicycle we invent). Gives
  real end-to-end encryption between avatars today, ~a few lines via a library,
  and is a clean throwaway when nuActor's semantics take over. Signature still
  authenticates.
- **(c) Our own envelope encryption.** Explicitly the bicycle you don't want.
  Rejected unless there's a reason NIP-44 can't fit.

➡️ **Recommend (b) NIP-44.** It threads your needle: encryption now, but a
*standard* not an invention, and disposable. The only cost is a WS+NIP-44 capable
client lib in Python (dependency risk noted for build). If minimizing throwaway
outranks having encryption locally, (a) is the fallback.

**Your answer:** lets do (a)


### R2-Q2 — Relay implementation

- **(a) Off-the-shelf relay image** (e.g. `nostr-rs-relay` — Rust, SQLite, simple
  TOML, ideal for a private closed relay) run host-side via the `launch` harness.
  Zero relay code to own; standard NIP-01 store+subscribe.
- **(b) Minimal custom relay in Python** (asyncio, ~150 lines) in a container we
  build like `bdd-runner`. One language across relay+CLI, every line ours, trivial
  to run closed — but our code to maintain.
- **(c) Custom relay in Go** (khatru/go-nostr). Aligns language with nuActor for an
  eventual merge — but the relay is exactly the piece nuActor *replaces*, so
  Go-aligning the disposable part buys little, and there's no Go in-sandbox to
  build/test (host-only).

➡️ **Recommend (a) off-the-shelf.** The relay is disposable transport; spend zero
effort owning it. `nostr-rs-relay` runs closed trivially. (I'll also **clone a
reference** into `/nunet-repos` per your note — proposing the **NIPs spec repo**
`nostr-protocol/nips` for the protocol + **`nbd-wtf/go-nostr`** for the Go client
shape we'll mirror in nuActor. OK to clone both?)

**Your answer:** agreed; (a)


### R2-Q3 — Actor-model alignment depth in v1

Given "alignment with the actor model is the key" — how much nuActor shape do we
bake in now?

- **(a) Mailbox-only.** Envelope carries just To/From/subject/thread/kind; actor
  semantics (behaviors, capabilities) deferred entirely to nuActor integration.
- **(b) Field-preserving shadow (recommended).** Envelope mirrors the nuActor
  `Envelope`/`Handle` JSON shape: `To`/`From` as `Handle{ID(npub),DID,Address}`, a
  `Behavior` field (default `/mailbox/message`), `ReplyTo` for threading, a `Nonce`,
  a `Signature` (implemented), and a `Capability` placeholder (present, **not**
  enforced in v1). Max alignment, minimum throwaway; the migration becomes
  field-mapping, not a rewrite.
- **(c) Full actor semantics now** — behaviors-as-handlers, UCAN capability
  verification. This *is* reimplementing nuActor: the bicycle. Rejected.

➡️ **Recommend (b).** Shadow the shape, implement only signature (cheap, real,
required by nuActor anyway); leave capability enforcement as a labelled placeholder
the actor runtime fills later.

**Your answer:** agreed with (b)


### R2-Q4 — Delivery semantics

- **(a) Best-effort + archive.** Relay stores events; the auto-archive to `inbox/`
  is the durability. No acks/retries.
- **(b) Best-effort + explicit read-receipt** (recommended). As (a), plus the
  reader emits a lightweight receipt event when it archives a message — because our
  standing rule is "a handoff is done only when the counterpart confirms." No
  transport-level retry machinery in v1 (relay persistence + archive covers loss).
- **(c) At-least-once** — acks + sender-side retry/dedupe. More machinery than a
  co-located trusted hub warrants now.

➡️ **Recommend (b).** Read-receipts fit the existing "done-is-confirmed-by-
counterpart" discipline and cost almost nothing; skip retries until the mesh era.

**Your answer:** (b) sounds good; it is better than what actor model semantics require at min...


### R2-Q5 — Key custody + address registry (grouped; confirm defaults)

- **Minting:** avatar-builder generates the secp256k1 keypair when it creates an
  avatar (same moment it wires secrets today).
- **Custody:** `nsec` (private key) injected via the existing `pass` / SANDBOX_SECRETS
  model, never in the tree (hard rule). `npub` + `did:key` are public.
- **Registry:** one checked-in `registry.json` in a shared location mapping
  `avatar-name → { npub, did:key, dids:[…], display }` — this *is* the Q2 identity
  mapping record and the discovery mechanism (replaces "know the folder path").

➡️ **Recommend as stated.** Confirm, or move any piece (e.g. self-minting on first
run instead of avatar-builder).

**Your answer:** i would rather that maintainer does the minting; or avatar-builder asks the operator do to id manually and add to pass; i do not want agents to mess with private keys at all;


### R2-Q6 — Ownership & provisioning (confirm the split)

Mirrors the QA-stack split we already run:

- **avatar-builder** provisions the **shared always-on relay** + the **shared docker
  network** every avatar joins, and mints/injects keys (R2-Q5). Cross-avatar infra
  is its domain.
- **This avatar (SE)** designs + builds the **`nostr-mailbox` tool** (Python CLI +
  envelope + registry format + the auto-archive-to-`inbox/` behavior) and the docs,
  as an installable skill/tool, and proves it end-to-end once the relay is up.

➡️ **Recommend as stated** (I build the portable parts; avatar-builder wires the
shared infra), with a handoff to avatar-builder like the QA one. Confirm.

**Your answer:** looks good, but what about having a separate container for the mailbox, not a skill? would that be nicer?


---

## ROUND 2 — SETTLED

- **R2-Q1 = (a)** signed plaintext, **no encryption** in v1 (adopt nuActor's crypto
  at integration; don't build a throwaway). Bonus: removes the WS+NIP-44 dependency.
- **R2-Q2 = (a)** off-the-shelf **`nostr-rs-relay`**, host-side. NIPs spec cloned to
  `/nunet-repos/nostr-nips` for reference.
- **R2-Q3 = (b)** field-preserving shadow of the nuActor `Envelope`/`Handle`.
- **R2-Q4 = (b)** best-effort + explicit read-receipt.
- **R2-Q5 = AMENDED — HARD RULE: agents never touch private keys.** The
  operator/maintainer mints each keypair and stores the `nsec` in `pass`;
  avatar-builder hands the operator the exact command block (maintainer-handoff) and
  wires injection. No agent generates, reads, or holds a private key.
- **R2-Q6 = you asked: container instead of a skill?** → escalated to R3-Q1 below;
  combined with R2-Q5 it becomes the recommended shape.

---

## ROUND 3 — the frontier unblocked by Round 2

### Forward-compat frame (from your NuNet + external-relay vision, 2026-08-25)

End-state: relays run independently on NuNet; agents are pure clients that fetch
from them; and agents can ALSO receive from **outside** NuNet via normal public
Nostr relays. This does not overturn the container or the schema — it refines them:

- **Multi-relay by design.** The container holds a **relay list** (foreshadowing
  NIP-65 read/write relay lists), not one URL. v1 = the local hub; later = NuNet
  relays + public relays at once. Reinforces R3-Q1=(a) (the container owns the set).
- **Profile-aware envelope.** v1 custom kind `3838` + plaintext is the **internal
  profile**. The **external profile** (added later) = standard encrypted DMs
  (**NIP-17 over NIP-44**) — because plaintext on public relays leaks, and normal
  clients expect standard DM kinds. So R2-Q1's "no encryption" is scoped
  **internal-only**; external re-introduces encryption via the *standard*. Our v1
  events are already valid NIP-01 (real sig), so a public relay could carry them
  today — only the semantics are private (external *read* interop is already free).
- **`cap` placeholder = the external-trust seam.** Internally the key set is closed
  (no spam problem). External senders re-introduce spam/trust; the unenforced `cap`
  tag is exactly where a future allowlist / capability gate lands — nuActor's
  marginal-trust/KYC model.
- **Unknown-sender handling.** External mail comes from pubkeys not in
  `registry.json`; the container must archive gracefully, falling back to the raw
  npub as `from`, and reserve the spot for a future allowlist.

### R3-Q1 — Delivery mechanism: mailbox **container** vs CLI-skill (your R2-Q6 question)

- **(a) Per-avatar mailbox container (recommended).** A small always-on service on
  each avatar's docker network that: holds the injected `nsec`, keeps a subscription
  to the shared relay for this avatar's pubkey, **signs** outgoing messages, and
  **auto-archives** incoming ones into `inbox/`. The agent talks to it over a
  **local HTTP API** (`curl`, already in-sandbox) — "send this body to `avatar-x`",
  "list unread". **The agent never sees the `nsec`.**
- **(b) CLI-skill only.** A Python CLI in the sandbox does the WS + signing + archive
  on demand. Simpler to ship, but (i) the `nsec` would have to be reachable by the
  agent's process — **violates R2-Q5**; (ii) not always-on, so mail only lands when
  the agent remembers to run `sync`.
- **(c) Hybrid.** Container for receive/archive + a thin CLI the agent uses to send.
  (This is really (a) with a nicer send ergonomic — see the CLI note.)

➡️ **Recommend (a), with a thin CLI wrapper for ergonomics** (the CLI just `curl`s
the container). It is the *only* option that honors R2-Q5 — the key lives in the
container, the container signs, the agent is never trusted with it — and it is the
closest thing to an actor: the container is a proto-`SecurityContext` + inbox. It is
also always-on, so mail arrives in `inbox/` between turns without the agent doing
anything. Migration story: this container becomes the nuActor actor runtime; the
local HTTP API becomes `Send`/`Receive`.

**Your answer:** sounds good;


### R3-Q2 — Concrete envelope schema (map nuActor `Envelope` onto a NIP-01 event)

The Nostr event **is** the wire envelope. Proposed mapping (v1):

| nuActor `Envelope`/`Handle` | Nostr event field / tag | v1 value |
|---|---|---|
| `From.ID` (pubkey) | `pubkey` | sender pubkey (hex) |
| `From.DID` | tag `["from_did", …]` | sender `did:key` |
| `To.ID` (pubkey) | tag `["p", …]` | recipient pubkey (hex) — relays route on this |
| `To.DID` | tag `["to_did", …]` | recipient `did:key` |
| `Behavior` | tag `["behavior", …]` | `/mailbox/message` (default) |
| `Options.ReplyTo` | tag `["e", <id>, "", "reply"]` | thread parent event id (NIP-10) |
| `Nonce` | `created_at` + `id` | (event id already unique) |
| `Capability` | tag `["cap", ""]` | **placeholder, empty, unenforced in v1** |
| `Signature` | `sig` | schnorr over the event id (this *is* the msg signature) |
| `Message` (payload) | `content` | the markdown body |
| (subject) | tag `["subject", …]` | human subject line (NIP-14) |
| (provenance) | tags `["from_name",…]`,`["to_name",…]` | avatar names, for the archive filename |

- **Event kind:** `3838` (a fixed **regular** kind in 1000–9999 so relays *persist*
  it; deliberately not 20000–29999 which are ephemeral/unstored, nor 10000–19999
  which are replaceable/overwritten). Read-receipt = kind `3839`, an `["e", <orig
  id>]` back-reference from the recipient. (Kind numbers are arbitrary-but-fixed;
  say if you want different ones.)
- **Archived `inbox/` file:** `YYYY-MM-DD-from-<sender>-<subject-slug>.md` (today's
  convention), with YAML frontmatter carrying the envelope fields (`event_id`,
  `from`, `from_did`, `to`, `behavior`, `reply_to`, `created_at`, `sig`) above the
  markdown body — self-describing and greppable.
- **Registry (`registry.json`, checked in, the Q2 identity record):**
  `avatar-name → { npub, pubkey_hex, did:key, dids:[…], display }`. The container
  resolves a recipient *name* → `pubkey_hex` for the `p` tag.

➡️ ~~Recommend as tabled.~~ **SUPERSEDED by your wrap idea → see R3-Q2-REVISED below.**

**Your answer:** this is too technical for me; i wonder if we can wrap nuActor envolope into Nostr envelope? That would allow us to use both protocols without adjusting / mapping and related problems... Then we actually would use Nostre -- only as messaging transrport, nuActor will kick in when a mesage is onwrapped... this probably changes some of the answers in round 1 and 2...

---

### R3-Q2-REVISED — Layered "wrap" model (your idea; ADOPTED)

**Decision: wrap the whole nuActor `Envelope` inside the Nostr event; Nostr is pure
transport, nuActor is the message.** This is better than the mapping table and is
the purest form of the root "decouple semantics from transport" principle. Two
clean layers, no field-by-field mapping to keep in sync:

**Outer — Nostr event (transport + mail-UX only):**
- `pubkey` = sender pubkey (so relays index it)
- `["p", <recipient pubkey hex>]` = the ONLY routing datum relays act on
- `kind` = `3838` (regular/persisted; also = **envelope-format version** marker)
- `created_at`, and Nostr `sig` = container-signed → **transport authenticity (v1's
  real guarantee)**
- convenience tags `["subject",…]`, `["from_name",…]`, `["to_name",…]` — used ONLY
  to build the archive filename / let humans filter. **No actor semantics here.**

**Inner — `content` = verbatim nuActor `Envelope` JSON** (tags already fixed in
`actor/interface.go`): `{to,from:{id,did,addr}, be:"/mailbox/message", nonce,
opt:{cont:<reply-to>, topic}, msg:<body>, cap, sig}`. The container wraps on send,
unwraps on receive; today it archives the unwrapped Envelope to `inbox/`; at nuActor
integration the SAME bytes go to the runtime's `Receive`. **Migration = delete the
wrapper.**

**Layered security (correct, not a compromise):**
- Outer Nostr `sig` = transport auth — implemented in v1 (container signs w/ nsec).
- Inner Envelope `sig` + `cap` = nuActor capability auth — **empty in v1**, filled by
  the real SecurityContext later. We do NOT fake it (that would be the bicycle).
- Confidentiality: none internal in v1; external-profile encryption (R3-Q3) is
  applied at whichever layer fits — NIP-17 outer for public relays, nuActor's own
  encryption inner for the nuActor mesh.

**Ripple to earlier rounds:** Q1/Q2/R2-Q1/R2-Q2/R2-Q4/R2-Q5/R3-Q1/R3-Q3 all
*reinforced*. **R2-Q3 upgraded** from "shadow fields into tags" → "carry the real
Envelope." **R3-Q2 mapping table retired.**

**Two confirmations needed:**
- **C1 — v1 inner signature:** leave inner `sig`/`cap` **empty** in v1 (rely on outer
  Nostr sig), runtime fills them later. ➡️ recommend yes.
- **C2 — versioning:** the `kind` (3838) encodes envelope-format version, so a future
  nuActor struct change is detectable and only the container's wrap/unwrap updates.
  ➡️ recommend yes.

**Your answer:** nuActor envelopes are signed by actors with cap contexts — that's
the FUTURE integration question; we don't have it now → **v1 uses plain Nostr
messages.**

---

### R3-Q2-FINAL — v1 = plain Nostr messages (SETTLED)

Don't embed a nuActor `Envelope` (not even empty-fielded) in v1. Send plain Nostr:

- `kind` **3838** (regular/persisted; also the format-version marker, C2).
- `content` = the **markdown body**, plaintext.
- `pubkey` + Nostr `sig` = sender identity + authenticity (container signs).
- tags (mail-UX + routing only): `["p", <recipient pubkey hex>]` (routing),
  `["subject",…]`, `["from_name",…]`, `["to_name",…]` (archive filename),
  `["e", <parent id>, "", "reply"]` (threading).
- Any Nostr client can read it; **nothing nuActor-specific embedded**.

**Alignment preserved without a struct** — via the two things that DON'T change at
integration: (1) identity = secp256k1 key / npub (= nuActor's actor ID), (2) Nostr =
swappable transport. At nuActor integration the container starts producing real
signed `Envelope`s (or swaps transport to libp2p); identity, registry, relay, and
the `inbox/` archive convention are untouched. **The wrap idea is the documented
migration path, not v1 code.**

C1 = yes (no inner envelope at all in v1). C2 = yes (kind marks the version).


### R3-Q3 — Internal/external identity boundary (new, from your NuNet + public-relay vision)

When the agent both talks internally (NuNet relays) and receives externally (public
relays), is its mailbox:

- **(i) One identity, profile-per-destination (recommended).** A single npub. The
  container picks the profile by destination/relay: internal plaintext on NuNet
  relays, standard encrypted DM on public relays. An external contact reaches the
  agent at the *same* npub an internal one does.
- **(ii) Two identities bridged.** A separate internal-only key and a public-facing
  key, reconciled by a bridge. Isolates external exposure, but re-creates the
  two-identities problem we spent Q2 avoiding.

➡️ **Recommend (i).** Keeps "npub is THE canonical address" true across the boundary;
the container (which already holds the key and selects the relay set) is the natural
place to select the profile too. Revisit only if a security review later wants the
public key physically separated from internal traffic.

**Your answer:** yea, (i) sounds good. ocnsidering also the answer to R3-q2...

---

## ROUND 3 — SETTLED

- **R3-Q1 = (a)** per-avatar mailbox container + thin CLI wrapper.
- **R3-Q2 = plain Nostr messages** (kind 3838, content=markdown, mail-UX tags, Nostr
  sig). No nuActor struct in v1; wrapping is the documented migration path.
- **R3-Q3 = (i)** one npub, profile-per-destination.

---

## ROUND 4 — final frontier (build specifics)

### R4-Q1 — Container implementation language

The container is the one always-on, alignment-relevant component (holds key,
subscribes, signs, archives, serves a local HTTP API). It runs **host-side** either
way (no in-sandbox runtime constrains it). At nuActor integration it is largely
*absorbed* into DMS's Go actor system regardless of language.

- **(a) Python** — fastest to build; rich libs (`websockets` + a BIP-340 schnorr lib
  like `coincurve`, or `pynostr`). Since it's absorbed into nuActor-Go at
  integration, the language doesn't carry forward anyway → optimize for ship speed.
- **(b) Go** (`nbd-wtf/go-nostr`) — batteries-included events/schnorr/relay; matches
  nuActor's Go if we want the container to be a literal seed of the runtime. But I
  can't compile/test Go (or Python) in-sandbox — both are host-built — so this buys
  alignment, not local testability.

➡️ **Lean (a) Python** for v1 speed (the container is rewritten into nuActor-Go at
integration, so language now doesn't persist). Pick (b) if you'd rather the
container be a real Go seed of the actor runtime. Your call — this is the one place
"alignment" and "ship fast" genuinely trade off.

**Your answer:** i would like (b) actually -- python is a kind af a lliability; otherwisie rust maybe? i will compile stuff no problem;


### R4-Q2 — CLI surface + boot integration (confirm defaults)

- **CLI (thin `curl` wrappers over the container API):** `mailbox send <to>
  --subject <s> [--reply <id>] <body|->`, `mailbox list [--unread]`, `mailbox read
  <id>`, `mailbox reply <id> <body>`, `mailbox contacts` (dumps the registry).
- **Boot integration:** none needed beyond what exists — the container auto-archives
  into `inbox/`, so the current "read `inbox/` on boot" habit already surfaces new
  mail. Optionally the boot report prints "N unread from <senders>".

➡️ **Recommend as stated.** Confirm, or adjust the verb set / add the boot summary.

**Your answer:** I actually do not understand now why we need cli on the reouter side; ths signing and all this stuff seem to be needed on the agent side... so this has to be done into a skill; what bout the router / mailbox has api only an dthe cli side is the skill on the agent avatar / archedtype side, which enables this? However there is question of keys then sure; hm. alright, a thin wrapper then. so when it comes to nuActor, the messages will be signedon th eactor and then double signed into nostr envelope in the mailbox?


### R4-Q3 — v1 build scope, ownership, acceptance demo (confirm)

- **I (SE) build the portable parts:** the mailbox container (send/receive/sign/
  archive/local API), the thin CLI, the `registry.json` format + seed, the usage
  docs, and the avatar-builder handoff spec. Lives in `tools/nostr-mailbox/`
  (mirrors `tools/bdd-runner/`).
- **avatar-builder provisions shared infra:** the always-on `nostr-rs-relay`, the
  shared docker network every avatar joins, the injected keys, and the shared
  `registry.json` location. Plus the **maintainer command block** for the operator to
  mint each keypair → `pass` (R2-Q5: agents never touch keys).
- **Acceptance demo (the proof):** two avatars exchange a signed `kind 3838` message
  through the shared relay; it auto-archives to the recipient's `inbox/`; a read-
  receipt returns; signature verifies. Real exec proof = the container-driven run
  (host-side, with avatar-builder), since I can't run docker in-sandbox — I build +
  manually review + HTTP-probe, they stand up infra, joint verify.

➡️ **Recommend as stated** (QA-stack-style split + handoff). Confirm, or move a
boundary.

**Your answer:** agreed with what is recommended;


---

## ROUND 4 — RESOLUTION

- **R4-Q1 = Go (SETTLED).** `nbd-wtf/go-nostr`. The container converges into
  nuActor/DMS (Go) → future co-location with the `actor` package = the alignment
  north star. (Rust considered — nicer standalone daemon, matches the relay — but
  diverges from nuActor; rejected.)
- **R4-Q2 = SETTLED.** CLI = a **thin, keyless skill on the agent/archetype side**
  (hands body to the container, holds no key). Container = **API only** (holds the
  `nsec`, signs the Nostr event, subscribes, archives to `inbox/`). Verb set as
  tabled; boot unchanged (auto-archive feeds the existing inbox-read).
  - **Signing model (your double-sign question), answered:** *v1* = **one** sig,
    the outer Nostr sig, done by the container; agent never holds the key. *nuActor
    end-state* = **double** sig — the **actor** signs its inner `Envelope`
    (capability context, inside its allocation/microVM) + the **mailbox** signs the
    outer Nostr event (transport). Correct two-layer auth. R2-Q5's "key isolated in
    a container" is the v1 stand-in for nuActor's "key in the actor's SecurityContext
    inside an allocation" — same trajectory.
- **R4-Q3 = SETTLED** (agreed): SE builds portable parts (`tools/nostr-mailbox/`);
  avatar-builder provisions relay + shared network + injected keys + maintainer
  key-mint block; acceptance = two avatars exchange a signed `kind 3838`, auto-
  archive, receipt, sig verifies; proven host-side.

---

## NEXT — pick Go/Rust, then I write the design doc (no code until you approve it)

One decision left (R4-Q1: Go or Rust). Once you pick, the frontier is empty and I
turn this record into a clean **design doc** (`design/nostr-mailbox.md`):
architecture + the two layers, identity model, envelope/kinds/tags, registry,
ownership split, the v1→nuActor migration path (incl. the double-sign end-state),
and a phased build plan + acceptance. **You approve THAT doc before any code** —
per "explain design before coding / grill design before shipping."
