#!/usr/bin/env bash
# tests/two-relays.sh -- the real mailbox over two real relays that only partly
# overlap, the way avatars on different machines see them.
#
#   GATED_RELAY=<nostr-relay>/relay/gated_relay.py [RELAY_PYTHON=python3] tests/two-relays.sh
#
# Needs a relay to run, so it SKIPS (exit 0, and says so) without GATED_RELAY: the
# gated relay from the nostr-relay repo, with its two python dependencies.
#
#   a reads both relays     b reads only "public"     c reads only "local"
#   d reads both, through a different URL for "public" than a uses
set -uo pipefail

[[ -n "${GATED_RELAY:-}" ]] || { echo "SKIPPED: set GATED_RELAY to nostr-relay's relay/gated_relay.py"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"
MAILBOX="$here/../mailbox"
PY="${RELAY_PYTHON:-python3}"
PL="${RELAY_TEST_PORT:-17470}"; PP=$((PL + 1))
T="$(mktemp -d)"
export HOME="$T/home"; mkdir -p "$HOME"   # nak keeps state in ~/.config/nak
PIDS=()
cleanup() { (( ${#PIDS[@]} )) && kill "${PIDS[@]}" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

declare -A K P
for n in a b c d; do K[$n]="$(nak key generate)"; P[$n]="$(printf %s "${K[$n]}" | nak key public)"; done

relay() { # <name> <port> <its URLs as a toml list> -> starts it, records the pid
    printf '[network]\naddress = "127.0.0.1"\nport = %s\n[gate]\nrelay_urls = %s\n[authorization]\npubkey_whitelist = [%s]\n' \
        "$2" "$3" "$(printf '"%s",' "${P[@]}")" > "$T/$1.toml"
    RELAY_CONFIG="$T/$1.toml" RELAY_DB="$T/$1.sqlite3" "$PY" -I "$GATED_RELAY" > "$T/$1.log" 2>&1 &
    local pid=$!; PIDS+=( "$pid" ); eval "PID_$1=$pid"
    for _ in $(seq 50); do curl -sf "http://127.0.0.1:$2/health" >/dev/null && break; sleep 0.1; done
    # Up AND ours: a stale relay on the port would answer for a dead one.
    curl -sf "http://127.0.0.1:$2/health" >/dev/null && kill -0 "$pid" 2>/dev/null \
        || { echo "relay $1 did not start (port $2 taken?):"; cat "$T/$1.log"; exit 1; }
}
relay local  "$PL" "[\"ws://127.0.0.1:$PL\"]"
relay public "$PP" "[\"ws://127.0.0.1:$PP\", \"ws://localhost:$PP\"]"

L="{\"name\": \"local\", \"url\": \"ws://127.0.0.1:$PL\"}"
PUB="{\"name\": \"public\", \"url\": \"ws://127.0.0.1:$PP\"}"
PUB_D="{\"name\": \"public\", \"url\": \"ws://localhost:$PP\"}"
declare -A R=( [a]="$L, $PUB" [b]="$PUB" [c]="$L" [d]="$L, $PUB_D" )
for n in a b c d; do
    mkdir -p "$T/$n/tools/nostr-mailbox" "$T/$n/harness"
    echo "AVATAR_NAME=$n" > "$T/$n/harness/config"
    echo "{\"relays\": [${R[$n]}]}" > "$T/$n/tools/nostr-mailbox/relays.json"
    jq -n --arg a "${P[a]}" --arg b "${P[b]}" --arg c "${P[c]}" --arg d "${P[d]}" '{
        a: {npub: "npub-a", pubkey_hex: $a},
        b: {npub: "npub-b", pubkey_hex: $b, relays: ["public"]},
        c: {npub: "npub-c", pubkey_hex: $c, relays: ["local"]},
        d: {npub: "npub-d", pubkey_hex: $d}}' > "$T/$n/tools/nostr-mailbox/registry.json"
done
mb() { local n="$1"; shift; AVATAR_ROOT="$T/$n" NOSTR_MAILBOX_NSEC="${K[$n]}" "$MAILBOX" "$@" 2>&1; }
on() { NOSTR_SECRET_KEY="${K[$1]}" timeout 15 nak req --auth -k 3838 --tag "p=${P[$2]}" "$3" 2>/dev/null | grep -c '^{'; }

fails=0
check() { if (( $2 )); then printf '  FAIL  %s\n' "$1"; fails=$((fails+1)); else printf '  ok    %s\n' "$1"; fi; }
echo ""

# --- send: only to a relay the recipient reads; default first -------------------
out="$(mb a send b --subject "to b" "body")"
check "a -> b (reads only public): sent via public"     "$(grep -q "via ws://127.0.0.1:$PP" <<<"$out"; echo $?)"
check "  and nothing was left on local"                 "$([[ "$(on b b "ws://127.0.0.1:$PL")" == 0 ]]; echo $?)"
check "b fetches it from the only relay it knows"       "$(mb b fetch | grep -q 'claimed 1 new'; echo $?)"

out="$(mb a send c --subject "to c" "body")"
check "a -> c (reads only local): sent via local"       "$(grep -q "via ws://127.0.0.1:$PL" <<<"$out"; echo $?)"
check "c fetches it"                                    "$(mb c fetch | grep -q 'claimed 1 new'; echo $?)"

out="$(mb a send d --subject "to d" "body")"
check "a -> d (reads both): the default, local"         "$(grep -q "via ws://127.0.0.1:$PL" <<<"$out"; echo $?)"
check "  and only there -- no broadcast"                "$([[ "$(on d d "ws://127.0.0.1:$PP")" == 0 ]]; echo $?)"
check "d fetches it"                                    "$(mb d fetch | grep -q 'claimed 1 new'; echo $?)"

out="$(mb b send c --subject "b to c" "body")"
check "b -> c, no relay in common: refused, not lost"   "$(grep -q 'none of our relays' <<<"$out" && ! grep -q 'sent to' <<<"$out"; echo $?)"

# --- two messages asking for receipts, in one fetch --------------------------------
mb a send d --ack --subject "one" "1" >/dev/null; mb a send d --ack --subject "two" "2" >/dev/null
check "d claims BOTH ack-requesting messages in one fetch" "$(mb d fetch | grep -q 'claimed 2 new'; echo $?)"
check "a gets both receipts"                            "$(mb a fetch | grep -q '2 ack(s)'; echo $?)"

# --- the default goes down -----------------------------------------------------------
kill "$PID_local"; wait "$PID_local" 2>/dev/null
out="$(mb a send d --ack --subject "while local is down" "body")"
check "local down: a -> d falls back to public"        "$(grep -q "via ws://127.0.0.1:$PP" <<<"$out"; echo $?)"
out="$(mb d fetch)"
check "d fetches it with local down -- and says local is down" \
                                                        "$(grep -q 'claimed 1 new' <<<"$out" && grep -q 'could not be read' <<<"$out"; echo $?)"
check "d's receipt reaches a by the fallback too"       "$(mb a fetch | grep -q '1 ack(s)'; echo $?)"
out="$(mb c fetch)"
check "c, whose only relay is down: the fetch FAILS"   "$(grep -q 'fetch failed' <<<"$out"; echo $?)"
out="$(mb a send c --subject "c is unreachable" "body")"
check "a -> c with local down: refused, nothing archived" \
                                                        "$(grep -q 'no relay took it' <<<"$out" && ! grep -rq 'c is unreachable' "$T/a/mail/.Sent"; echo $?)"

echo ""
if (( fails )); then for r in local public; do echo "  --- $r log ---"; sed 's/^/  | /' "$T/$r.log"; done; echo "  $fails check(s) failed"; exit 1; fi
echo "  all checks passed"
