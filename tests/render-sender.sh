#!/usr/bin/env bash
# tests/render-sender.sh -- the From: header names the key that signed.
#
# The registry maps keys to names, so the sender of a verified event is the name
# the registry gives its pubkey. A from_name tag is the author's own claim and
# could name anyone: render() must not believe it, and open_event() drops it,
# as it drops a type or task in the clear. The subject of encrypted mail is the
# one inside the ciphertext, not a tag beside it.
#
# Relay-free and key-free, as tests/render-recipient.sh: sourcing the tool stops
# before dispatch; nak_decrypt is replaced by a fixed plaintext.
#
# Run: tests/render-sender.sh   (exits non-zero if any case fails)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mailbox="$here/../mailbox"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ME=1111111111111111111111111111111111111111111111111111111111111111
MEMBER=2222222222222222222222222222222222222222222222222222222222222222
LEAD=3333333333333333333333333333333333333333333333333333333333333333
STRANGER=4444444444444444444444444444444444444444444444444444444444444444

mkdir -p "$work/harness" "$work/tools/nostr-mailbox" "$work/mail"
printf 'AVATAR_NAME=tester\n' > "$work/harness/config"
cat > "$work/tools/nostr-mailbox/registry.json" <<JSON
{
  "tester":    { "npub": "npub1tester",   "pubkey_hex": "$ME" },
  "member":    { "npub": "npub1member",   "pubkey_hex": "$MEMBER" },
  "tech-lead": { "npub": "npub1techlead", "pubkey_hex": "$LEAD" }
}
JSON

export AVATAR_ROOT="$work" MAILBOX_ROOT="$work/mail"
export NOSTR_MAILBOX_RELAY="ws://127.0.0.1:1"   # tests never reach a real relay
# shellcheck disable=SC1090
source "$mailbox" >/dev/null
nak_decrypt() { printf '%s' '{"subject":"real subject","body":"real body"}'; }

event() { # <author-hex> <extra tags as a JSON array>
    jq -nc --arg a "$1" --arg p "$ME" --argjson extra "$2" \
      '{ id: "deadbeef", created_at: 1788400000, kind: 3838, sig: "sig",
         pubkey: $a, content: "hi", tags: ([ ["p",$p] ] + $extra) }'
}

header() { # <header> -- on stdin: an event; prints the rendered header value
    render | sed -n "s/^$1: //p" | head -1
}

fails=0
is() { # <expected> <got> <label>
    if [[ "$1" == "$2" ]]; then printf 'ok: %s\n' "$3"
    else printf 'FAIL: %s -- expected %q, got %q\n' "$3" "$1" "$2"; fails=$((fails+1)); fi
}

out="$(event "$MEMBER" '[["from_name","tech-lead"],["subject","s"]]' | header From)"
is 'member <npub1member@nostr>' "$out" "a from_name tag cannot name another member"

out="$(event "$MEMBER" '[["subject","s"]]' | header From)"
is 'member <npub1member@nostr>' "$out" "the signer's registry name is the sender"

out="$(event "$STRANGER" '[["from_name","tech-lead"]]' | header From)"
is "unknown <$STRANGER@nostr>" "$out" "an unregistered signer is unknown, by its key"

encrypted="$(event "$MEMBER" '[["encrypted","nip44"],["from_name","tech-lead"],["subject","forged subject"]]')"
opened="$(printf '%s' "$encrypted" | open_event)"
is '0' "$(jq '[.tags[] | select(.[0]=="from_name")] | length' <<<"$opened")" "open_event drops a from_name tag"
out="$(printf '%s' "$opened" | header From)"
is 'member <npub1member@nostr>' "$out" "opened encrypted mail names its signer"
out="$(printf '%s' "$opened" | header Subject)"
is 'real subject' "$out" "the subject of encrypted mail comes from the ciphertext"

(( fails == 0 )) || { printf '%d case(s) failed\n' "$fails"; exit 1; }
printf 'all cases pass\n'
