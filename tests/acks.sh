#!/usr/bin/env bash
# tests/acks.sh -- a sender can ask for a receipt, and the receiver publishes one
# automatically at the two moments it can honestly claim: delivered (on the disk)
# and read (printed). Plus the checks that stop a tick being believed too easily.
#
# Relay-free, like tests/encrypt-and-unsend.sh: throwaway keys, real nak for the
# crypto, and the functions that touch the network replaced after sourcing.
# Acks are captured in a file rather than an array because some cases call
# cmd_fetch inside a command substitution, where an array would not survive.
#
# Run: tests/acks.sh   (exits non-zero if any case fails)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mailbox="$here/../mailbox"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

A_SEC="$(nak key generate)"; A="$(printf %s "$A_SEC" | nak key public)"   # tester (us)
B_SEC="$(nak key generate)"; B="$(printf %s "$B_SEC" | nak key public)"   # other
C_SEC="$(nak key generate)"; C="$(printf %s "$C_SEC" | nak key public)"   # third party
S_SEC="$(nak key generate)"; S="$(printf %s "$S_SEC" | nak key public)"   # stranger

cat > "$work/registry.json" <<JSON
{
  "tester": { "npub": "npub1tester", "pubkey_hex": "$A" },
  "other":  { "npub": "npub1other",  "pubkey_hex": "$B" },
  "third":  { "npub": "npub1third",  "pubkey_hex": "$C" }
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

as() { # <sec> <hex> <cmd...>
    local sec="$1" hex="$2"; shift 2
    ( NOSTR_SECRET_KEY="$sec" MY_HEX="$hex"; "$@" )
}

# A message event as it arrives: from <author> to us, optionally asking for a receipt.
msg() { # <author-hex> <ciphertext> [ack] [id]
    local tags='[["p",$p],["encrypted","nip44"]]'
    [[ "${3:-}" == ack ]] && tags='[["p",$p],["encrypted","nip44"],["ack","request"]]'
    jq -nc --arg a "$1" --arg p "$A" --arg c "$2" --arg i "${4:-ev$RANDOM}" \
        "{id: \$i, created_at: 1788400000, kind: 3838, sig: \"sig\", pubkey: \$a, content: \$c, tags: $tags}"
}

# An ack event as it arrives, from <author> about <message-id>.
ackev() { # <author-hex> <message-id> <delivered|read> [id]
    jq -nc --arg a "$1" --arg p "$A" --arg e "$2" --arg s "$3" --arg i "${4:-ak$RANDOM}" \
        '{id: $i, created_at: 1788400100, kind: 7, sig: "sig", pubkey: $a, content: "+",
          tags: [["e",$e],["p",$p],["k","3838"],["ack",$s]]}'
}

acked() { cat "$work/acked" 2>/dev/null || true; }

nak_verify() { cat >/dev/null; }                  # signatures are not what is under test
nak_ack() { printf '%s %s\n' "$1" "$3" >> "$work/acked"; echo '{}'; }
FEED=(); ACKFEED=()
nak_fetch()      { printf '%s\n' ${FEED[@]+"${FEED[@]}"}; }
nak_fetch_acks() { printf '%s\n' ${ACKFEED[@]+"${ACKFEED[@]}"}; }

# ── asking ───────────────────────────────────────────────────────────────────
# Signing is local (no relay), so the real nak signs and the tags are read back.
reqtag() { jq -r '[.tags[] | select(.[0]=="ack") | .[1]] | join(",")'; }
is request "$(nak_sign_message ct "$B" "" ack | reqtag)" "--ack tags the message with a request"
is ""      "$(nak_sign_message ct "$B" "" ""  | reqtag)" "without --ack there is no request tag"

ct="$(as "$B_SEC" "$B" seal "$A" "please confirm" "body")"
is yes "$(msg "$B" "$ct" ack | open_event | render | sed -n 's/^X-Nostr-Ack-Request: //p')" \
   "the archive records the request, which is where read() looks for it"
is "" "$(msg "$B" "$ct" | open_event | render | sed -n 's/^X-Nostr-Ack-Request: //p')" \
   "and records nothing when none was asked for"

# ── delivered, on fetch ──────────────────────────────────────────────────────
: > "$work/acked"
FEED=( "$(msg "$B" "$ct" ack m-one)" )
cmd_fetch >/dev/null 2>&1
is "m-one delivered" "$(acked)" "fetch acks a message that asked, once it is archived"
is 1 "$(find "$MAILBOX_ROOT/new" -type f -name '*.m-one.*' | wc -l)" "and the message is archived"

: > "$work/acked"
FEED=( "$(msg "$B" "$ct" "" m-two)" )
cmd_fetch >/dev/null 2>&1
is "" "$(acked)" "a message that did not ask gets no receipt"

# ── read, on the first read only ─────────────────────────────────────────────
: > "$work/acked"
cmd_read m-one >/dev/null
is "m-one read" "$(acked)" "the first read acks read"
: > "$work/acked"
cmd_read m-one >/dev/null
is "" "$(acked)" "re-reading is not a new fact and sends nothing"

: > "$work/acked"
cmd_read m-two >/dev/null
is "" "$(acked)" "reading a message that did not ask sends nothing"

# ── an ack never costs the mail ──────────────────────────────────────────────
: > "$work/acked"
nak_ack() { return 1; }                            # the receipt cannot be published
FEED=( "$(msg "$B" "$ct" ack m-three)" )
rc=0; out="$(cmd_fetch 2>&1)" || rc=$?
is 0 "$rc" "a receipt that will not publish does not fail the fetch"
is 1 "$(find "$MAILBOX_ROOT/new" -type f -name '*.m-three.*' | wc -l)" "and the mail is still archived"
[[ "$out" == *"the mail is fine, the receipt is not"* ]] && is 1 1 "and it says so" || is 1 0 "and it says so"
nak_ack() { printf '%s %s\n' "$1" "$3" >> "$work/acked"; echo '{}'; }

# ── no receipts to ourselves ─────────────────────────────────────────────────
: > "$work/acked"
ack_publish self "$A" delivered
is "" "$(acked)" "we do not ack our own mail to ourselves"

# ── claiming acks for mail WE sent ───────────────────────────────────────────
sent_to() { # <id> <recipient-name> -> a fake sent archive entry
    local p="$SENT/cur/1788400000.$1.tester:2,S"
    { printf 'From: tester <npub1tester@nostr>\n'
      printf 'To: %s <npub1%s@nostr>\n' "$2" "$2"
      printf 'Subject: s\nX-Nostr-Event-Id: %s\n' "$1"; } > "$p"
}
sent_to s-one other

ACKFEED=( "$(ackev "$B" s-one delivered a-1)" )
is 1 "$(ack_claim)" "an ack from the addressee, for mail we sent, is claimed"
is delivered "$(ack_state s-one)" "and the sender can see it"
ACKFEED=( "$(ackev "$B" s-one delivered a-1)" )
is 0 "$(ack_claim)" "claiming the same ack twice records it once"

ACKFEED=( "$(ackev "$B" s-one read a-2)" )
is 1 "$(ack_claim)" "a read ack for the same message is also claimed"
is read "$(ack_state s-one)" "and read outranks delivered -- one tick is enough"

# ── what must not be believed ────────────────────────────────────────────────
ACKFEED=( "$(ackev "$C" s-one delivered a-3)" )
is 0 "$(ack_claim)" "an ack from someone the message was not addressed to is refused"
ACKFEED=( "$(ackev "$S" s-one delivered a-4)" )
is 0 "$(ack_claim)" "an ack from a key not in the registry is refused"
ACKFEED=( "$(ackev "$B" s-never delivered a-5)" )
is 0 "$(ack_claim)" "an ack for a message we never sent is refused"
ACKFEED=( "$(ackev "$B" s-one nonsense a-6)" )
is 0 "$(ack_claim)" "an ack with an unknown state is refused"

# ── the filename invariant ───────────────────────────────────────────────────
# The ack filename holds the acked id glued with a dash, not a dot, precisely so
# that md_has -- which globs *.<id>.* over the whole maildir -- cannot mistake a
# receipt for the message itself and report unfetched mail as already held.
: > "$ACKS/cur/1788400100.a-7.ack-s-orphan-delivered.tester"
md_has s-orphan && is 1 0 "an ack does not make its message look already held" \
                || is 1 1 "an ack does not make its message look already held"
is 1 "$(find "$ACKS/cur" -name '*.a-7.*' | wc -l)" "while the ack itself is still found by its own id"

# ── the listing ──────────────────────────────────────────────────────────────
out="$(cmd_list --all)"
[[ "$out" == *read* ]] && is 1 1 "list --all shows the ack state of mail we sent" || is 1 0 "list --all shows the ack state of mail we sent"
printf 'From: tester <x@nostr>\nTo: other <y@nostr>\nSubject: s\nX-Nostr-Event-Id: s-wait\nX-Nostr-Ack-Request: yes\n' \
    > "$SENT/cur/1788400000.s-wait.tester:2,S"
out="$(cmd_list --all)"
[[ "$out" == *"awaiting ack"* ]] && is 1 1 "a requested ack that has not arrived reads as awaiting, not silence" \
                                 || is 1 0 "a requested ack that has not arrived reads as awaiting, not silence"

if (( fails )); then printf '\n%d case(s) FAILED\n' "$fails"; exit 1; fi
printf '\nall ack cases passed\n'
