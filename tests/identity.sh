#!/usr/bin/env bash
# tests/identity.sh -- the mailbox works out which avatar it is.
#
# Identity is resolved at load time from AVATAR_NAME in the avatar's own
# harness/config, because nothing injects it into the agent container. This is
# relay-free and key-free: sourcing the tool runs the resolution and stops before
# dispatch (the BASH_SOURCE guard), so no event is ever built or sent.
#
# Run: tests/identity.sh   (exits non-zero if any case fails)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mailbox="$here/../mailbox"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fixture() { # <name> [<config line>...] -- an avatar root; no lines = no config file
    local d="$work/$1"; shift
    mkdir -p "$d/harness" "$d/tools/nostr-mailbox" "$d/mail"
    (( $# )) && printf '%s\n' "$@" > "$d/harness/config"
    cat > "$d/tools/nostr-mailbox/registry.json" <<'JSON'
{
  "tester": { "npub": "npub1tester", "pubkey_hex": "1111111111111111111111111111111111111111111111111111111111111111" },
  "other":  { "npub": "npub1other",  "pubkey_hex": "2222222222222222222222222222222222222222222222222222222222222222" }
}
JSON
    printf '%s' "$d"
}

resolved() { # <avatar-root> [<MAILBOX_AVATAR>] -- prints what it resolved, empty if it refused
    (
        export AVATAR_ROOT="$1" MAILBOX_ROOT="$1/mail"
        export NOSTR_MAILBOX_RELAY="ws://127.0.0.1:1"   # tests never reach a real relay
        if [[ -n "${2:-}" ]]; then export MAILBOX_AVATAR="$2"; else unset MAILBOX_AVATAR; fi
        # shellcheck disable=SC1090
        source "$mailbox" >/dev/null 2>&1 || exit 0
        printf '%s' "${MAILBOX_AVATAR:-}"
    )
}

fails=0
is() { # <expected> <got> <label>
    if [[ "$1" == "$2" ]]; then printf 'ok: %s\n' "$3"
    else printf 'FAIL: %s -- expected %q, got %q\n' "$3" "$1" "$2"; fails=$((fails+1)); fi
}

plain="$(fixture plain 'AVATAR_NAME=tester')"
is tester "$(resolved "$plain")" "resolves AVATAR_NAME from harness/config"

# The config is hand-edited by operators: quoted values and leading whitespace are
# both things it really contains, and neither may leak into the identity.
messy="$(fixture messy '# a comment' '   AVATAR_NAME="tester"' 'OTHER=x')"
is tester "$(resolved "$messy")" "tolerates quotes, indentation and other keys"

is other "$(resolved "$plain" other)" "an explicit MAILBOX_AVATAR still wins"

bare="$(fixture bare)"
is "" "$(resolved "$bare")" "refuses when there is no config to read"

# ...and says where it looked, rather than naming a variable nobody has heard of.
out="$(AVATAR_ROOT="$bare" MAILBOX_ROOT="$bare/mail" "$mailbox" contacts 2>&1 || true)"
if grep -qF 'cannot tell which avatar this is' <<<"$out" && grep -qF "$bare/harness/config" <<<"$out"; then
    printf 'ok: the failure says where it looked\n'
else
    printf 'FAIL: unhelpful failure message\n  got: %s\n' "$out"; fails=$((fails+1))
fi

if (( fails )); then printf '\n%d case(s) FAILED\n' "$fails"; exit 1; fi
printf '\nall identity cases passed\n'
