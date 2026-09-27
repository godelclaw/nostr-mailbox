#!/usr/bin/env bash
# tests/encrypt-and-unsend.sh -- bodies are NIP-44 encrypted, fetch fails closed
# on unknown senders and undecryptable mail, and delete unsends only our own mail
# and only claims success when the relay stopped serving it.
#
# Relay-free: throwaway keys, real nak for the crypto, and the three functions
# that touch the network (nak_fetch, nak_delete, nak_get) replaced after sourcing.
# That the relay honours NIP-09 at all was probed live against nostr-rs-relay.
#
# Run: tests/encrypt-and-unsend.sh   (exits non-zero if any case fails)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mailbox="$here/../mailbox"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

A_SEC="$(nak key generate)"; A="$(printf %s "$A_SEC" | nak key public)"   # tester (us)
B_SEC="$(nak key generate)"; B="$(printf %s "$B_SEC" | nak key public)"   # other
C_SEC="$(nak key generate)"; C="$(printf %s "$C_SEC" | nak key public)"   # stranger

cat > "$work/registry.json" <<JSON
{
  "tester": { "npub": "npub1tester", "pubkey_hex": "$A" },
  "other":  { "npub": "npub1other",  "pubkey_hex": "$B" }
}
JSON

export MAILBOX_AVATAR=tester MAILBOX_REGISTRY="$work/registry.json" MAILBOX_ROOT="$work/mail"
export NOSTR_MAILBOX_RELAY="ws://127.0.0.1:1"   # tests never reach a real relay
export NOSTR_MAILBOX_NSEC="$A_SEC"
# shellcheck disable=SC1090
source "$mailbox" >/dev/null
md_init

fails=0
is() { # <expected> <got> <label>
    if [[ "$1" == "$2" ]]; then printf 'ok: %s\n' "$3"
    else printf 'FAIL: %s -- expected %q, got %q\n' "$3" "$1" "$2"; fails=$((fails+1)); fi
}

as() { # <sec> <hex> <cmd...> -- run as another avatar's key
    local sec="$1" hex="$2"; shift 2
    ( NOSTR_SECRET_KEY="$sec" MY_HEX="$hex"; "$@" )
}

event() { # <author-hex> <to-hex> <content> [plaintext]
    local tags='[["p",$p],["encrypted","nip44"]]'
    [[ "${4:-}" == plaintext ]] && tags='[["p",$p],["subject","old"]]'
    jq -nc --arg a "$1" --arg p "$2" --arg c "$3" \
        "{id: \"ev$RANDOM\", created_at: 1788400000, kind: 3838, sig: \"sig\", pubkey: \$a, content: \$c, tags: $tags}"
}

body=$'line one\n"quoted" $(not run)\n\ntrailing blank lines\n\n'

# ── seal / open ──────────────────────────────────────────────────────────────
ct="$(as "$B_SEC" "$B" seal "$A" "the subject" "$body")"
[[ "$ct" != *"line one"* ]] && is 1 1 "the ciphertext does not contain the body" || is 1 0 "the ciphertext does not contain the body"

opened="$(event "$B" "$A" "$ct" | open_event)"
got="$(jq -j '.content' <<<"$opened"; printf x)"; got="${got%x}"   # keep trailing newlines
is "$body" "$got" "the recipient opens the body byte for byte"
is "the subject" "$(jq -r '.tags[] | select(.[0]=="subject") | .[1]' <<<"$opened")" "the subject comes back from inside the ciphertext"

# Our own sent copy: NIP-44 is symmetric, so the author opens it with the p key.
mine="$(seal "$B" "to other" "hello")"
is hello "$(event "$A" "$B" "$mine" | open_event | jq -r .content)" "the sender opens its own sent copy"

rc=0; event "$B" "$A" "$ct" | as "$C_SEC" "$C" open_event >/dev/null 2>&1 || rc=$?
is 1 "$(( rc != 0 ))" "a third key cannot open it"

is "legacy" "$(event "$B" "$A" legacy plaintext | open_event | jq -r .content)" "a plaintext event from an older mailbox passes through"

rc=0; ( seal "$B" s "$(head -c 70000 /dev/zero | tr '\0' a)" ) >/dev/null 2>&1 || rc=$?
is 1 "$(( rc != 0 ))" "a message over the NIP-44 limit is refused"

is nip44 "$(event "$B" "$A" "$ct" | open_event | render | sed -n 's/^X-Nostr-Encryption: //p')" "the archive records the encryption"
is "the subject" "$(event "$B" "$A" "$ct" | open_event | render | sed -n 's/^Subject: //p')" "the rendered Subject is the decrypted one"

# ── fetch fails closed ───────────────────────────────────────────────────────
nak_verify() { cat >/dev/null; }                 # signatures are not what is under test
FEED=()
nak_fetch() { printf '%s\n' "${FEED[@]}"; }

FEED=( "$(event "$C" "$A" "$(as "$C_SEC" "$C" seal "$A" x y)")" )
out="$(cmd_fetch 2>&1)"
[[ "$out" == *"sender is not in the registry"* ]] && is 1 1 "an unregistered sender is rejected" || is 1 0 "an unregistered sender is rejected"
is 0 "$(find "$MAILBOX_ROOT/new" -type f | wc -l)" "and nothing is archived"

FEED=( "$(event "$B" "$A" "not-ciphertext")" )
out="$(cmd_fetch 2>&1)"
[[ "$out" == *"cannot decrypt"* ]] && is 1 1 "undecryptable mail is rejected" || is 1 0 "undecryptable mail is rejected"

FEED=( "$(event "$B" "$A" "$ct")" )
cmd_fetch >/dev/null 2>&1
f="$(find "$MAILBOX_ROOT/new" -type f | head -1)"
is "the subject" "$(hdr "$f" Subject)" "a registered, decryptable message is archived in the clear"

# ── delete ───────────────────────────────────────────────────────────────────
DELETED=()
nak_delete() { DELETED+=("$1"); echo '{}'; }
STILL_SERVED=no
nak_get() { [[ "$STILL_SERVED" == yes ]] && echo '{"id":"x"}' || true; }

sent_copy() { # <id> -> path of a fake sent archive entry
    local p="$SENT/cur/1788400000.$1.tester:2,S"; : > "$p"; printf '%s' "$p"
}

rc=0; ( cmd_delete nosuchid ) >/dev/null 2>&1 || rc=$?
is 1 "$(( rc != 0 ))" "mail we did not send cannot be unsent"

p="$(sent_copy aaaa)"; STILL_SERVED=yes
rc=0; ( cmd_delete aaaa ) >/dev/null 2>&1 || rc=$?
is 1 "$(( rc != 0 ))" "a relay that ignores NIP-09 is reported as a failure"
[[ -f "$p" ]] && is 1 1 "and the sent copy is not marked unsent" || is 1 0 "and the sent copy is not marked unsent"

p="$(sent_copy bbbb)"; STILL_SERVED=no
cmd_delete bbbb >/dev/null
is 1 "$(find "$SENT/cur" -name '*.bbbb.*:2,ST' | wc -l)" "an unsent message is flagged T in the archive"
( cmd_delete bbbb ) >/dev/null 2>&1
is 1 "$(find "$SENT/cur" -name '*.bbbb.*' | wc -l)" "unsending twice leaves one copy"

if (( fails )); then printf '\n%d case(s) FAILED\n' "$fails"; exit 1; fi
printf '\nall encrypt-and-unsend cases passed\n'
