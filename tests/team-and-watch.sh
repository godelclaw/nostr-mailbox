#!/usr/bin/env bash
# tests/team-and-watch.sh -- typed mail, the legality rules, and the watcher.
#
# Relay-free: throwaway keys and real nak for the crypto; publish_to and cmd_fetch
# are replaced after sourcing, mail "arrives" by being archived directly, and the
# session cycle is a fake that records what it was asked. The watcher types into
# a pane on a PRIVATE tmux socket, never the default server.
#
# Run: tests/team-and-watch.sh   (exits non-zero if any case fails)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mailbox="$here/../mailbox"

work="$(mktemp -d)"
sock="mbtest$$"
cleanup() { tmux -L "$sock" kill-session -t pane 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT

key() { local s; s="$(nak key generate)"; printf '%s %s' "$s" "$(printf %s "$s" | nak key public)"; }
read -r ME_SEC ME <<<"$(key)"; read -r LEAD_SEC LEAD <<<"$(key)"
read -r PEER_SEC PEER <<<"$(key)"; read -r KID_SEC KID <<<"$(key)"; read -r OUT_SEC OUT <<<"$(key)"

cat > "$work/registry.json" <<JSON
{ "me":   {"npub": "npub1me",   "pubkey_hex": "$ME"},
  "lead": {"npub": "npub1lead", "pubkey_hex": "$LEAD"},
  "peer": {"npub": "npub1peer", "pubkey_hex": "$PEER"},
  "kid":  {"npub": "npub1kid",  "pubkey_hex": "$KID"},
  "out":  {"npub": "npub1out",  "pubkey_hex": "$OUT"} }
JSON
# me: a child of lead, peer's review partner, and parent of kid.
cat > "$work/team.json" <<'JSON'
{ "team": "t", "parent": "lead", "children": ["kid"], "review": ["peer"],
  "limits": {"context_hard_max": 400000} }
JSON

cat > "$work/cycle" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/cycle.log"
case "$1" in
    idle)   exit "$(cat "$(dirname "$0")/idle")" ;;
    reset)  [[ -e "$(dirname "$0")/armed" ]] || { echo "not checkpointed"; exit 1; }; echo "reset ordered" ;;
    status) echo "context=1234 soft=120000 hard=250000" ;;
esac
SH
chmod +x "$work/cycle"; echo 0 > "$work/idle"

export MAILBOX_AVATAR=me MAILBOX_REGISTRY="$work/registry.json" MAILBOX_ROOT="$work/mail"
export MAILBOX_TEAM="$work/team.json" SESSION_CYCLE_BIN="$work/cycle"
export MAILBOX_WATCH_TMUX_SOCKET="$sock" MAILBOX_WATCH_ONCE=1
export NOSTR_MAILBOX_RELAY="ws://127.0.0.1:1"   # tests never reach a real relay
export NOSTR_MAILBOX_NSEC="$ME_SEC"
# shellcheck disable=SC1090
source "$mailbox" >/dev/null
md_init

# Nothing leaves: a publish is recorded, and a fetch claims nothing new.
publish_to() { printf '%s\n' "$2" >> "$work/published"; echo "ws://test"; }
cmd_fetch() { :; }

fails=0
is() { # <expected> <got> <label>
    if [[ "$1" == "$2" ]]; then printf 'ok: %s\n' "$3"
    else printf 'FAIL: %s -- expected %q, got %q\n' "$3" "$1" "$2"; fails=$((fails+1)); fi
}
yes_() { if "$@"; then echo 1; else echo 0; fi; }

hex() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
n=1791000000
# arrive <from-hex> <type> <task> <subject> <body> -> its id; archived as unread
arrive() {
    local id; id="$(hex)"; n=$((n+1))
    jq -nc --arg id "$id" --argjson c "$n" --arg a "$1" --arg p "$ME" --arg t "$2" --arg k "$3" \
           --arg s "$4" --arg b "$5" '
        {id: $id, created_at: $c, kind: 3838, sig: "sig", pubkey: $a, content: $b,
         tags: ([["p", $p], ["subject", $s]] + (if $t != "" then [["type", $t]] else [] end)
                                             + (if $k != "" then [["task", $k]] else [] end))}' \
        | render | md_deliver "$INBOX" "$id" "$n" "" new >/dev/null
    printf '%s' "$id"
}
sent() { # <to-hex> <type> -- archive mail we sent
    local id; id="$(hex)"; n=$((n+1))
    jq -nc --arg id "$id" --argjson c "$n" --arg a "$ME" --arg p "$1" --arg t "$2" '
        {id: $id, created_at: $c, kind: 3838, sig: "sig", pubkey: $a, content: "x",
         tags: ([["p", $p], ["subject", "s"]] + (if $t != "" then [["type", $t]] else [] end))}' \
        | render | md_deliver "$SENT" "$id" "$n" S cur >/dev/null
}

# ── the envelope ─────────────────────────────────────────────────────────────
ct="$(seal "$ME" "subj" "body" review T-7)"
[[ "$ct" != *review* && "$ct" != *T-7* ]] && is 1 1 "type and task are inside the ciphertext" || is 1 0 "type and task are inside the ciphertext"
ev="$(jq -nc --arg a "$LEAD" --arg p "$ME" --arg c "$(NOSTR_SECRET_KEY="$LEAD_SEC" seal "$ME" subj body review T-7)" \
      '{id:"e1",created_at:1,kind:3838,sig:"s",pubkey:$a,content:$c,tags:[["p",$p],["encrypted","nip44"],["type","reset"]]}')"
arch="$(printf '%s' "$ev" | open_event | render)"
is "X-Mailbox-Type: review" "$(grep '^X-Mailbox-Type' <<<"$arch")" "the type comes from the plaintext; a clear 'type' tag is dropped"
is "X-Mailbox-Task: T-7" "$(grep '^X-Mailbox-Task' <<<"$arch")" "the task id is archived as a header"
plain="$(jq -c '.tags += [["type","reset"]] | .tags |= map(select(.[0] != "encrypted"))' <<<"$ev" | open_event | render)"
is 0 "$(grep -c '^X-Mailbox-Type' <<<"$plain" || true)" "an unencrypted event cannot carry a type"
untyped="$(jq -nc --arg a "$LEAD" --arg p "$ME" --arg c "$(NOSTR_SECRET_KEY="$LEAD_SEC" seal "$ME" subj body)" \
      '{id:"e2",created_at:1,kind:3838,sig:"s",pubkey:$a,content:$c,tags:[["p",$p],["encrypted","nip44"]]}' | open_event | render)"
is 0 "$(grep -c '^X-Mailbox' <<<"$untyped" || true)" "untyped mail carries no type header"

# ── sending: the sender's own view ───────────────────────────────────────────
why() { illegal_out "$@" || true; }
is "" "$(why kid task T-1)"                       "a task goes to a child"
is "" "$(why lead checkpoint "")"                 "a checkpoint goes to the parent"
is "" "$(why peer review T-1)"                    "a review goes to the review partner"
is "" "$(why lead status "")"                     "status goes to anyone with an edge"
[[ "$(why lead task T-1)" == *"goes to your child"* ]] && is 1 1 "a task to the parent is refused" || is 1 0 "a task to the parent is refused"
[[ "$(why kid task "")" == *"needs a task id"* ]] && is 1 1 "a task without an id is refused" || is 1 0 "a task without an id is refused"
[[ "$(why out status "")" == *"not in this avatar's team"* ]] && is 1 1 "status to an outsider is refused" || is 1 0 "status to an outsider is refused"
[[ "$(why kid frobnicate "")" == *"unknown type"* ]] && is 1 1 "an unknown type is refused" || is 1 0 "an unknown type is refused"
[[ "$(why lead done T-9)" == *"needs an agree"* ]] && is 1 1 "done without an agree is refused" || is 1 0 "done without an agree is refused"
arrive "$OUT" agree T-9 "agree from an outsider" "x" >/dev/null
[[ "$(why lead done T-9)" == *"needs an agree"* ]] && is 1 1 "an agree from a non-partner does not count" || is 1 0 "an agree from a non-partner does not count"
agree_id="$(arrive "$PEER" agree T-9 "agreed" "checked the build")"
is "" "$(why lead done T-9)"                      "done with the partner's agree for that task is legal"

rc=0; out="$(cmd_send lead --subject s --type task --task T-1 "b" 2>&1)" || rc=$?
is 1 "$rc" "send refuses an illegal typed message"
[[ ! -f "$work/published" ]] && is 1 1 "and nothing was signed or published" || is 1 0 "and nothing was signed or published"
rc=0; ( cmd_send lead --subject s --task T-1 "b" ) >/dev/null 2>&1 || rc=$?
is 1 "$rc" "--task without --type is refused"
rc=0; ( cmd_send kid --subject "go" --type task --task T-1 "do it" ) >/dev/null 2>&1 || rc=$?
is 0 "$rc" "a legal typed send goes out"
f="$(find "$SENT/cur" -type f -newer "$work/team.json" | head -1)"
is "X-Mailbox-Type: task" "$(grep '^X-Mailbox-Type' "$f")" "and the sent copy is archived with its type"
rm -f "$f"

# ── receiving: the mirror image ──────────────────────────────────────────────
whyin() { illegal_in "$@" || true; }
is "" "$(whyin lead task T-1)"                    "a task from the parent is legal"
is "" "$(whyin kid checkpoint "")"                "a checkpoint from a child is legal"
[[ "$(whyin kid task T-1)" == *"comes from a parent"* ]] && is 1 1 "a task from a child is illegal" || is 1 0 "a task from a child is illegal"
[[ "$(whyin lead reset "")" == *"answers a checkpoint"* ]] && is 1 1 "a reset with no checkpoint sent is illegal" || is 1 0 "a reset with no checkpoint sent is illegal"
sent "$LEAD" checkpoint
is "" "$(whyin lead reset "")"                    "a reset after our checkpoint is legal"
sent "$LEAD" ""
is "" "$(whyin lead reset "")"                    "untyped mail after the checkpoint (a status answer) does not void it"
sent "$LEAD" stuck
[[ "$(whyin lead reset "")" == *"answers a checkpoint"* ]] && is 1 1 "a reset is illegal once we sent anything after the checkpoint" || is 1 0 "a reset is illegal once we sent anything after the checkpoint"
sent "$LEAD" checkpoint

# ── list, prefixes, mark-read ────────────────────────────────────────────────
line="$(cmd_list | grep "${agree_id:0:8}")"
[[ "$line" == *unread*peer*"[agree] agreed"* ]] && is 1 1 "list: one line with state, short id, sender, type, subject" || is 1 0 "list: one line with state, short id, sender, type, subject -- $line"
is "$(md_find "$agree_id")" "$(md_find "${agree_id:0:8}")" "an 8-character prefix finds the message"
( cmd_mark_read "${agree_id:0:8}" ) >/dev/null
[[ -z "$(find "$INBOX/new" -name "*$agree_id*")" ]] && is 1 1 "mark-read moves it out of new/" || is 1 0 "mark-read moves it out of new/"
( cmd_mark_read --all ) >/dev/null
is "  0 unread" "$(cmd_list)" "an empty inbox says so"

# ── the watcher ──────────────────────────────────────────────────────────────
tmux -L "$sock" new-session -d -s pane -x 400 -y 50 'cat'
pane_has() { tmux -L "$sock" capture-pane -p -J -t pane | grep -qF -- "$1"; }

# First start: what was waiting is the session's; nothing typed.
old="$(arrive "$LEAD" "" "" "from before" "x")"
( cmd_watch pane ) 2>/dev/null
pane_has "from before" && is 0 1 "the first start leaves the backlog alone" || is 0 0 "the first start leaves the backlog alone"

# Prose while the session is mid-turn: held, not typed, not forgotten.
echo 1 > "$work/idle"
p1="$(arrive "$PEER" "" "" "hello there" "x")"
( cmd_watch pane ) 2>/dev/null
pane_has "hello there" && is 0 1 "nothing is typed while the session is busy" || is 0 0 "nothing is typed while the session is busy"
is 1 "$(grep -c 'held 1 new: session busy' "$WATCH/log")" "holding it is logged"
( cmd_watch pane ) 2>/dev/null
is 1 "$(grep -c 'held 1 new: session busy' "$WATCH/log")" "once, not on every pass"
echo 0 > "$work/idle"
( cmd_watch pane ) 2>/dev/null; sleep 0.3
pane_has "[mailbox] 1 new: from peer \"hello there\" (${p1:0:8})" && is 1 1 "between turns, the session is woken with one line" || is 1 0 "between turns, the session is woken with one line"
seen_once="$(tmux -L "$sock" capture-pane -p -J -t pane | grep -c 'hello there')"
( cmd_watch pane ) 2>/dev/null; sleep 0.3
is "$seen_once" "$(tmux -L "$sock" capture-pane -p -J -t pane | grep -c 'hello there')" "and only once"
is 1 "$(yes_ test -n "$(find "$INBOX/new" -name "*$p1*")")" "woken mail stays unread until the session reads it"
is 0 "$(grep -c 'read .* held message' "$WATCH/log")" "typed mail is not reported as read by the session itself"

# Held during a turn, then read by the session before the watcher could type it.
echo 1 > "$work/idle"
p2="$(arrive "$PEER" "" "" "read it myself" "x")"
( cmd_watch pane ) 2>/dev/null
( cmd_mark_read --all ) >/dev/null
echo 0 > "$work/idle"
( cmd_watch pane ) 2>/dev/null; sleep 0.3
pane_has "read it myself" && is 0 1 "mail the session already read is not typed" || is 0 0 "mail the session already read is not typed"
is 1 "$(grep -c 'the session read 1 held message(s) itself' "$WATCH/log")" "and the log says the session read it"

# An illegal typed message: bounced, flagged, never typed.
: > "$work/published"
bad="$(arrive "$KID" task T-2 "do my bidding" "x")"
( cmd_watch pane ) 2>/dev/null; sleep 0.3
pane_has "do my bidding" && is 0 1 "an illegal message is not typed" || is 0 0 "an illegal message is not typed"
is 1 "$(grep -c . "$work/published")" "it is sent back"
[[ -n "$(find "$INBOX/cur" -name "*$bad*:2,RST")" ]] && is 1 1 "and archived as refused" || is 1 0 "and archived as refused"
[[ "$(cmd_list --all | grep "${bad:0:8}")" == *refused* ]] && is 1 1 "list --all shows it refused" || is 1 0 "list --all shows it refused"

# Control mail.
: > "$work/cycle.log"
r1="$(arrive "$LEAD" reset "" "reset" "next: T-3")"
( cmd_watch pane ) 2>/dev/null
[[ -n "$(find "$INBOX/cur" -name "*$r1*:2,RST")" ]] && is 1 1 "a legal reset the cycle refuses (not armed) is bounced" || is 1 0 "a legal reset the cycle refuses (not armed) is bounced"
touch "$work/armed"; sent "$LEAD" checkpoint
r2="$(arrive "$LEAD" reset "" "reset" "next: T-3")"
( cmd_watch pane ) 2>/dev/null
is 2 "$(grep -c '^reset' "$work/cycle.log")" "a reset goes to the session cycle"
[[ -n "$(find "$INBOX/new" -name "*$r2*")" ]] && is 1 1 "and stays unread for the fresh session" || is 1 0 "and stays unread for the fresh session"
pane_has "next: T-3" && is 0 1 "and is not typed" || is 0 0 "and is not typed"

l1="$(arrive "$LEAD" limits "" "limits" "context_hard=500000")"
( cmd_watch pane ) 2>/dev/null
[[ -n "$(find "$INBOX/cur" -name "*$l1*:2,RST")" ]] && is 1 1 "limits over the team's ceiling are bounced" || is 1 0 "limits over the team's ceiling are bounced"
l2="$(arrive "$LEAD" limits "" "limits" $'context_soft=150000\ncontext_hard=300000')"
( cmd_watch pane ) 2>/dev/null
is "limits context_soft=150000 context_hard=300000" "$(grep '^limits' "$work/cycle.log")" "limits within the ceiling reach the session cycle"

: > "$work/published"
s1="$(arrive "$LEAD" status "" "status?" "x")"
( cmd_watch pane ) 2>/dev/null
is 1 "$(grep -c . "$work/published")" "status is answered without the model"
reply_body="$(jq -r .content "$work/published" | while read -r c; do NOSTR_SECRET_KEY="$LEAD_SEC" nak_decrypt "$ME" "$c"; done | jq -r .body)"
is "context=1234 soft=120000 hard=250000" "$reply_body" "with the session cycle's own status"

# Receipts are required: every send asks, and the watcher names what has none.
is "X-Nostr-Ack-Request: yes" "$(grep -h '^X-Nostr-Ack-Request' "$(find "$SENT/cur" -type f -newer "$work/published" | head -1)")" \
    "every message asks for a receipt, without --ack"
late() { # <to-hex> <age-seconds> <subject> -> id; sent mail that asked for a receipt
    local id; id="$(hex)"; local c=$(( $(date +%s) - $2 ))
    jq -nc --arg id "$id" --argjson c "$c" --arg a "$ME" --arg p "$1" --arg s "$3" '
        {id: $id, created_at: $c, kind: 3838, sig: "sig", pubkey: $a, content: "x",
         tags: [["p", $p], ["subject", $s], ["ack", "request"]]}' \
        | render | md_deliver "$SENT" "$id" "$c" S cur >/dev/null
    printf '%s' "$id"
}
lost="$(late "$PEER" 700 "lost in transit")"
late "$PEER" 60 "just sent" >/dev/null
got="$(late "$PEER" 700 "made it")"
: > "$ACKS/cur/1.ackid.ack-$got-delivered.me"
( cmd_watch pane ) 2>/dev/null; sleep 0.3
pane_has "NOT DELIVERED after 10 min, no receipt: to peer \"lost in transit\" (${lost:0:8})" \
    && is 1 1 "mail with no receipt after 10 minutes is raised" || is 1 0 "mail with no receipt after 10 minutes is raised"
pane_has "just sent" && is 0 1 "fresh mail is not" || is 0 0 "fresh mail is not"
pane_has "made it" && is 0 1 "nor mail with a receipt" || is 0 0 "nor mail with a receipt"
before="$(tmux -L "$sock" capture-pane -p -J -t pane | grep -c 'lost in transit')"
( cmd_watch pane ) 2>/dev/null; sleep 0.3
is "$before" "$(tmux -L "$sock" capture-pane -p -J -t pane | grep -c 'lost in transit')" "and it is raised once"

# Two watchers: the second refuses.
exec 8>"$WATCH/lock"; flock -n 8
rc=0; ( cmd_watch pane ) >/dev/null 2>&1 || rc=$?
is 6 "$rc" "a second watcher for the same avatar refuses to start (6)"
exec 8>&-

if (( fails )); then printf '\n%d case(s) FAILED\n' "$fails"; exit 1; fi
printf 'all team-and-watch cases passed\n'
