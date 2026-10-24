#!/usr/bin/env bash
# tests/install.sh -- a re-install replaces each file by rename, never in place.
#
# A running watcher is a bash process reading `mailbox` as it goes; a `cp` onto
# the same inode hands it half-old, half-new bytes. So the re-installed file
# must be a NEW inode with the same content and mode, the old inode must stay
# whole for a reader that still has it open, and no temp file may be left over.
#
# Run: tests/install.sh   (exits non-zero if any case fails)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
install="$here/../scripts/install"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A minimal avatar: one synced harness, a config, a .gitignore.
av="$work/avatar"
mkdir -p "$av/harness/claude" "$av/harness/core"
: > "$av/harness/claude/entrypoint.sh"
echo 'SANDBOX_SECRETS="NOSTR_MAILBOX_NSEC=pass:x"' > "$av/harness/config"
echo 'tmp/' > "$av/.gitignore"

fails=0
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
ok()   { printf 'ok: %s\n' "$*"; }

bin="$av/tools/nostr-mailbox/mailbox"

"$install" "$av" >/dev/null
[[ -x "$bin" ]] && ok "first install: mailbox is executable" || fail "first install: mailbox not executable"

# Stand in for an older version (same inode), held open by the "running watcher".
echo '# old version' > "$bin"
before="$(stat -c %i "$bin")"
exec 3<"$bin"
"$install" "$av" >/dev/null
after="$(stat -c %i "$bin")"

[[ "$before" != "$after" ]] && ok "re-install: new inode" || fail "re-install: same inode $before (overwritten in place)"
cmp -s "$here/../mailbox" "$bin"     && ok "re-install: content identical" || fail "re-install: content differs"
[[ -x "$bin" ]]                       && ok "re-install: still executable" || fail "re-install: lost the exec bit"
[[ "$(cat <&3)" == '# old version' ]] && ok "re-install: open reader still sees the whole old file" \
                                      || fail "re-install: open reader sees changed bytes"
exec 3<&-

for sk in "$here/../skills"/*/; do
    sk="$(basename "$sk")"
    cmp -s "$here/../skills/$sk/SKILL.md" "$av/skills/$sk/SKILL.md" \
        && ok "skill $sk installed" || fail "skill $sk missing or differs"
done

left="$(find "$av" -name '*.install.*' -print)"
[[ -z "$left" ]] && ok "no temp files left" || fail "temp files left: $left"

pre="$(stat -c %i "$bin")"
"$install" "$av" --dry-run >/dev/null
[[ "$(stat -c %i "$bin")" == "$pre" ]] && ok "dry run: file untouched" || fail "dry run replaced the file"

(( fails == 0 )) && { echo "all ok"; exit 0; }
echo "$fails failed"; exit 1
