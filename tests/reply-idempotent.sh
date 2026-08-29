#!/usr/bin/env bash
# tests/reply-idempotent.sh -- marking a message replied is idempotent.
#
# Replying to a thread twice must not mv the Maildir file onto itself. This
# sources the tool for md_mark_replied (the BASH_SOURCE guard skips dispatch) so
# it needs no relay and no key.
#
# Run: tests/reply-idempotent.sh   (exits non-zero on failure)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mailbox="$here/../mailbox"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/registry.json" <<'JSON'
{ "tester": { "npub": "npub1tester", "pubkey_hex": "1111111111111111111111111111111111111111111111111111111111111111" } }
JSON
export MAILBOX_AVATAR="tester"
export MAILBOX_REGISTRY="$work/registry.json"
export MAILBOX_ROOT="$work/mail"
export NOSTR_MAILBOX_NSEC=""
# No test may resolve a real relay address: sourcing the tool inherits its
# NOSTR_MAILBOX_RELAY default, so pin it unreachable.
export NOSTR_MAILBOX_RELAY="ws://127.0.0.1:1"

# The fixture above (env + registry) MUST precede this source: the tool runs
# MAILBOX_AVATAR:? and reads the registry with jq at source time.
# shellcheck disable=SC1090
source "$mailbox"          # defines functions; dispatch is skipped when sourced
mkdir -p "$MAILBOX_ROOT"/{new,cur}

fails=0
here_is() { [[ -f "$1" ]] || { printf 'FAIL: %s\n' "$2"; fails=$((fails+1)); }; }
gone()    { [[ ! -e "$1" ]] || { printf 'FAIL: %s\n' "$2"; fails=$((fails+1)); }; }

# unread (new/) -> cur/…:2,SR  (a move, not a copy)
f="$MAILBOX_ROOT/new/100.aaa.tester"; : > "$f"
md_mark_replied "$f"
here_is "$MAILBOX_ROOT/cur/100.aaa.tester:2,SR" "new/ was not marked replied"
gone    "$f"                                     "new/ source left behind (copy, not move)"

# seen (cur/…:2,S) -> cur/…:2,SR  (a move, not a copy)
f="$MAILBOX_ROOT/cur/200.bbb.tester:2,S"; : > "$f"
md_mark_replied "$f"
here_is "$MAILBOX_ROOT/cur/200.bbb.tester:2,SR" "seen was not marked replied"
gone    "$f"                                     "seen source left behind (copy, not move)"

# already replied (cur/…:2,SR) -> no error, file stays (the bug this fixes)
f="$MAILBOX_ROOT/cur/300.ccc.tester:2,SR"; : > "$f"
md_mark_replied "$f"       # must not error on mv-onto-itself
here_is "$f" "replying twice lost or errored on the file"

if (( fails )); then printf '\n%d case(s) FAILED\n' "$fails"; exit 1; fi
printf 'all reply-idempotent cases passed\n'
