#!/usr/bin/env bash
# tests/body-guards.sh -- the body is inline or a file (never stdin), and a body
# that is empty / whitespace-only is refused whichever way it arrived.
#
# The refusal cases fail BEFORE any relay call. The "accepts" cases only assert
# the body guard let them THROUGH: the publish then fails against an unreachable
# relay (pinned below), which is not a body-guard refusal. A real end-to-end send
# is covered by live QA, not here.
#
# Run: tests/body-guards.sh   (exits non-zero if any case fails)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mailbox="$here/../mailbox"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/registry.json" <<'JSON'
{
  "tester":    { "npub": "npub1tester", "pubkey_hex": "1111111111111111111111111111111111111111111111111111111111111111" },
  "recipient": { "npub": "npub1recip",  "pubkey_hex": "2222222222222222222222222222222222222222222222222222222222222222" }
}
JSON

export MAILBOX_AVATAR="tester"
export MAILBOX_REGISTRY="$work/registry.json"
export MAILBOX_ROOT="$work/mail"
# Pin the relay to an unreachable address: the "accepts" cases must never touch a
# real relay. An empty NSEC does NOT error -- nak falls back to a machine default
# key and would publish -- so the suite's safety has to be its own, not the
# relay's access control being up to reject an unregistered key.
export NOSTR_MAILBOX_RELAY="ws://127.0.0.1:1"
export NOSTR_MAILBOX_NSEC=""

fails=0
run() { "$mailbox" "$@" </dev/null 2>&1; }   # merged output; never reads stdin

# the guard must REFUSE: non-zero exit AND a matching message
refuses() { # <fragment> -- <args...>
    local want="$1"; shift; [[ "$1" == "--" ]] && shift
    local out rc=0; out="$(run "$@")" && rc=0 || rc=$?
    if (( rc == 0 )); then printf 'FAIL: expected refusal for: %s\n' "$*"; fails=$((fails+1)); return; fi
    if ! grep -qF "$want" <<<"$out"; then
        printf 'FAIL: refused but message missing %q\n  got: %s\n' "$want" "$out"; fails=$((fails+1)); return; fi
    printf 'ok: refuses (%s)\n' "$want"
}

# the guard must ACCEPT: the body passes the guard (failure, if any, is NOT a body refusal)
accepts() { # <label> -- <args...>
    local label="$1"; shift; [[ "$1" == "--" ]] && shift
    local out; out="$(run "$@")" || true
    if grep -qiE 'refusing to send|no body|not both|body file not found|single quoted argument' <<<"$out"; then
        printf 'FAIL: body was rejected but should pass (%s)\n  got: %s\n' "$label" "$out"; fails=$((fails+1)); return; fi
    printf 'ok: accepts (%s)\n' "$label"
}

printf ''            > "$work/empty"
printf '   \n\t\n'   > "$work/whitespace"
printf 'a real body' > "$work/good"

refuses "no body"                       -- send recipient --subject s
refuses "body file not found"           -- send recipient --subject s --body-file "$work/nope"
refuses "empty or only whitespace"      -- send recipient --subject s --body-file "$work/empty"
refuses "empty or only whitespace"      -- send recipient --subject s --body-file "$work/whitespace"
refuses "empty or only whitespace"      -- send recipient --subject s ""
refuses "empty or only whitespace"      -- send recipient --subject s "   "
refuses "not both"                      -- send recipient --subject s --body-file "$work/good" "also inline"
refuses "single quoted argument"        -- send recipient --subject s one two three

accepts "inline body"                   -- send recipient --subject s "a one-line message"
accepts "--body-file"                   -- send recipient --subject s --body-file "$work/good"

if (( fails )); then printf '\n%d case(s) FAILED\n' "$fails"; exit 1; fi
printf '\nall body-guard cases passed\n'
