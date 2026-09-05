#!/usr/bin/env bash
# tests/render-recipient.sh -- the To: header names the actual recipient.
#
# render() serves both directions: the inbox path, where the addressee is us, and
# the .Sent archive, where it is the other avatar. It used to hardcode our own
# name, so every archived outgoing message claimed to have been sent to its own
# author. The recipient comes from the event's "p" tag, which nak_publish sets on
# send and nak_fetch filters on, so it is present and correct either way.
#
# Relay-free and key-free: sourcing the tool stops before dispatch, and render()
# is pure -- event JSON in, headers out.
#
# Run: tests/render-recipient.sh   (exits non-zero if any case fails)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mailbox="$here/../mailbox"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ME=1111111111111111111111111111111111111111111111111111111111111111
THEM=2222222222222222222222222222222222222222222222222222222222222222

mkdir -p "$work/harness" "$work/tools/nostr-mailbox" "$work/mail"
printf 'AVATAR_NAME=tester\n' > "$work/harness/config"
cat > "$work/tools/nostr-mailbox/registry.json" <<JSON
{
  "tester": { "npub": "npub1tester", "pubkey_hex": "$ME" },
  "other":  { "npub": "npub1other",  "pubkey_hex": "$THEM" }
}
JSON

export AVATAR_ROOT="$work" MAILBOX_ROOT="$work/mail"
export NOSTR_MAILBOX_RELAY="ws://127.0.0.1:1"   # tests never reach a real relay
# shellcheck disable=SC1090
source "$mailbox" >/dev/null

event() { # <author-hex> <p-hex> <from_name>
    jq -nc --arg a "$1" --arg p "$2" --arg f "$3" \
      '{ id: "deadbeef", created_at: 1788400000, kind: 3838, sig: "sig",
         pubkey: $a, content: "hi",
         tags: [ ["p",$p], ["subject","s"], ["from_name",$f] ] }'
}

header() { # <header> -- on stdin: an event; prints the rendered header value
    render | sed -n "s/^$1: //p" | head -1
}

fails=0
is() { # <expected> <got> <label>
    if [[ "$1" == "$2" ]]; then printf 'ok: %s\n' "$3"
    else printf 'FAIL: %s -- expected %q, got %q\n' "$3" "$1" "$2"; fails=$((fails+1)); fi
}

# The archive path: our own message, on its way to someone else.
out="$(event "$ME" "$THEM" tester | header To)"
is 'other <npub1other@nostr>' "$out" "an outgoing message is addressed to its recipient"

# The inbox path, unchanged: mail we fetched is tagged for us.
out="$(event "$THEM" "$ME" other | header To)"
is 'tester <npub1tester@nostr>' "$out" "an incoming message is addressed to us"

out="$(event "$THEM" "$ME" other | header From)"
is 'other <npub1other@nostr>' "$out" "the sender is unaffected"

# An unregistered or missing key must not render an empty addressee.
out="$(event "$ME" 00ff00ff tester | header To)"
is 'tester <npub1tester@nostr>' "$out" "falls back when the recipient is not in the registry"

if (( fails )); then printf '\n%d case(s) FAILED\n' "$fails"; exit 1; fi
printf '\nall render-recipient cases passed\n'
