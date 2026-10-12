#!/usr/bin/env bash
# tests/relays.sh -- which relay a message goes to, and which ones are read.
#
# relays.json lists relays in order of preference; a send stops at the first one
# that takes the message and the recipient reads; reads go to all of them. Relay-
# free: nak_put and nak_relay are replaced after sourcing, so the order of the
# calls IS the observation.
#
# Run: tests/relays.sh   (exits non-zero if any case fails)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mailbox="$here/../mailbox"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

A_SEC="$(nak key generate)"; A="$(printf %s "$A_SEC" | nak key public)"
B="$(nak key generate | nak key public)"; C="$(nak key generate | nak key public)"
D="$(nak key generate | nak key public)"

cat > "$work/registry.json" <<JSON
{
  "tester":  { "npub": "npub1tester",  "pubkey_hex": "$A" },
  "anywhere":{ "npub": "npub1any",     "pubkey_hex": "$B" },
  "faraway": { "npub": "npub1far",     "pubkey_hex": "$C", "relays": ["public"] },
  "nowhere": { "npub": "npub1nowhere", "pubkey_hex": "$D", "relays": ["elsewhere"] }
}
JSON
cat > "$work/relays.json" <<JSON
{ "relays": [ { "name": "local",  "url": "ws://local:1",   "note": "the default" },
              { "name": "public", "url": "wss://public:1", "note": "the fallback" } ] }
JSON

export MAILBOX_AVATAR=tester MAILBOX_REGISTRY="$work/registry.json" MAILBOX_ROOT="$work/mail"
export MAILBOX_RELAYS="$work/relays.json" NOSTR_MAILBOX_NSEC="$A_SEC"
unset NOSTR_MAILBOX_RELAY

fails=0
is() { # <expected> <got> <label>
    if [[ "$1" == "$2" ]]; then printf 'ok: %s\n' "$3"
    else printf 'FAIL: %s -- expected %q, got %q\n' "$3" "$1" "$2"; fails=$((fails+1)); fi
}
lines() { tr '\n' ' ' | sed 's/ $//'; }

# ── the list itself ──────────────────────────────────────────────────────────
is "local public" "$( source "$mailbox" >/dev/null; echo "${RELAY_NAMES[*]}" )" "relays.json is read in its order"
is "ws://nostr-relay:8080" "$( MAILBOX_RELAYS="$work/none.json"; source "$mailbox" >/dev/null; echo "${RELAY_URLS[*]}" )" \
   "no relays.json: the one local relay, as before"
is "ws://x:1" "$( NOSTR_MAILBOX_RELAY=ws://x:1; source "$mailbox" >/dev/null; echo "${RELAY_URLS[*]}" )" \
   "NOSTR_MAILBOX_RELAY overrides relays.json"
for bad in '{}' '{"relays": []}' '{"relays": [{"name": "a"}]}' '{"relays": [{"name": "a", "url": "http://a"}]}' \
           '{"relays": [{"name": "a", "url": "ws://a"}, {"name": "a", "url": "ws://b"}]}' 'not json'; do
    printf '%s' "$bad" > "$work/bad.json"
    rc=0; ( MAILBOX_RELAYS="$work/bad.json"; source "$mailbox" ) >/dev/null 2>&1 || rc=$?
    is 1 "$rc" "a broken relays.json stops, it is not guessed around: $bad"
done

# shellcheck disable=SC1090
source "$mailbox" >/dev/null
md_init

# ── routing ──────────────────────────────────────────────────────────────────
is "ws://local:1 wss://public:1" "$(routes_to anywhere | lines)" "a contact naming no relays: all of ours, in our order"
is "wss://public:1"              "$(routes_to faraway  | lines)" "a contact naming its relays: only those"
is ""                            "$(routes_to nowhere  | lines)" "no relay in common: nothing"

# ── default, then the next one ───────────────────────────────────────────────
DOWN=""   # relays that refuse
nak_put() { echo "$2" >> "$work/tried"; [[ " $DOWN " != *" $2 "* ]]; }

: > "$work/tried"; via="$(publish_to anywhere '{}' 2>/dev/null)"
is "ws://local:1" "$via" "the default takes it"
is "ws://local:1" "$(lines < "$work/tried")" "and nothing else is tried -- no broadcast"

: > "$work/tried"; DOWN="ws://local:1"; via="$(publish_to anywhere '{}' 2>/dev/null)"
is "wss://public:1" "$via" "the default refuses: the fallback takes it"
is "ws://local:1 wss://public:1" "$(lines < "$work/tried")" "tried in order"

: > "$work/tried"; DOWN=""; via="$(publish_to faraway '{}' 2>/dev/null)"
is "wss://public:1" "$via" "a contact that reads only the fallback is sent there directly"
is "wss://public:1" "$(lines < "$work/tried")" "the default it does not read is never tried"

: > "$work/tried"; DOWN="ws://local:1 wss://public:1"; rc=0; publish_to anywhere '{}' >/dev/null 2>&1 || rc=$?
is 4 "$rc" "every relay refuses: the publish fails, as refused (4)"

: > "$work/tried"; DOWN=""; rc=0; out="$(publish_to nowhere '{}' 2>&1)" || rc=$?
is 1 "$rc" "no relay in common: the publish fails"
is "" "$(cat "$work/tried")" "without trying a relay the recipient never reads"
[[ "$out" == *"none of our relays"* ]] && is 1 1 "and it says why" || is 1 0 "and it says why"

# ── a send is the same signed event wherever it lands ───────────────────────
: > "$work/tried"; DOWN="ws://local:1"
nak_put() { echo "$2 $(jq -r .id <<<"$1")" >> "$work/tried"; [[ " $DOWN " != *" $2 "* ]]; }
out="$(cmd_send anywhere --subject s "hello" 2>&1)"
ids="$(cut -d' ' -f2 "$work/tried" | sort -u | wc -l)"
is 1 "$ids" "the fallback gets the very event the default refused -- one id, not two messages"
[[ "$out" == *"via wss://public:1"* ]] && is 1 1 "send says which relay took it" || is 1 0 "send says which relay took it"
is 1 "$(find "$SENT/cur" -type f | wc -l)" "and it is archived once"

: > "$work/tried"; DOWN="ws://local:1 wss://public:1"; rc=0
( cmd_send anywhere --subject s "hello again" ) >/dev/null 2>&1 || rc=$?
is 4 "$rc" "no relay takes it: the send fails, as refused (4)"
is 1 "$(find "$SENT/cur" -type f | wc -l)" "and nothing more is archived"

# ── reads go everywhere ──────────────────────────────────────────────────────
nak_relay() { # <req> <args...> <url>
    local url="${*: -1}"; echo "$url" >> "$work/read"
    [[ " $DOWN " == *" $url "* ]] && return 3
    echo "{\"from\":\"$url\"}"
}
: > "$work/read"; DOWN=""
is '{"from":"ws://local:1"} {"from":"wss://public:1"}' "$(nak_fetch | lines)" "fetch reads every relay"
: > "$work/read"; DOWN="ws://local:1"; rc=0; got="$(nak_fetch 2>/dev/null)" || rc=$?
is "0 {\"from\":\"wss://public:1\"}" "$rc $got" "one relay down: the others are still read"
: > "$work/read"; DOWN="ws://local:1 wss://public:1"; rc=0; nak_fetch >/dev/null 2>&1 || rc=$?
is 4 "$rc" "every relay down: the fetch fails (4), so 'no mail' never hides 'no relay'"

# ── doctor names an unreachable contact ──────────────────────────────────────
out="$(cmd_doctor 2>&1)" || true
[[ "$out" == *"UNREACHABLE: nowhere"* ]] && is 1 1 "doctor names a contact we share no relay with" || is 1 0 "doctor names a contact we share no relay with"
[[ "$out" != *"UNREACHABLE: faraway"* ]] && is 1 1 "but not one we reach by the fallback" || is 1 0 "but not one we reach by the fallback"

echo ""
(( fails == 0 )) && echo "all relay cases pass" || { echo "$fails case(s) failed"; exit 1; }
