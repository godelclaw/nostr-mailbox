#!/usr/bin/env bash
# tests/keys-dir.sh -- the private key goes to pass (or, --throwaway, to fd 3 and
# nowhere else); the public halves go to $KEYS_DIR; build-registry reads them
# there; drop-avatar-keys takes back exactly what mint wrote.
#
# Stubs nak and pass on PATH: no key store, no docker.
#
# Run: tests/keys-dir.sh   (exits non-zero if any case fails)
set -uo pipefail   # no -e: cases below fail on purpose and read $?

here="$(cd "$(dirname "$0")" && pwd)"
scripts="$here/../scripts"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/store"
export PASSWORD_STORE_DIR="$T/store" KEYS_DIR="$T/keys" PATH="$T/bin:$PATH"

# nak: a random 64-hex secret; its "public key" is its sha256; npub is a fixed
# valid-charset string derived from the hex.
cat > "$T/bin/nak" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "key generate") od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; echo ;;
    "key public")   sha256sum | cut -c1-64 ;;
    "encode npub")  echo "npub1$(printf %s "$3" | tr 0-9a-f 023456789acdef | cut -c1-58)" ;;
    *) exit 9 ;;
esac
EOF
# pass: insert/rm/show on plain files under $PASSWORD_STORE_DIR.
cat > "$T/bin/pass" <<'EOF'
#!/usr/bin/env bash
f() { echo "$PASSWORD_STORE_DIR/$1.gpg"; }
case "$1" in
    insert) p="${*: -1}"; mkdir -p "$(dirname "$(f "$p")")"; cat > "$(f "$p")" ;;
    rm)     p="${*: -1}"; rm -f "$(f "$p")" ;;
    show)   cat "$(f "$2")" ;;
    *) exit 9 ;;
esac
EOF
chmod +x "$T/bin/nak" "$T/bin/pass"

fails=0
fail() { printf 'FAIL: %s\n' "$*"; fails=$((fails+1)); }
ok()   { printf 'ok: %s\n' "$*"; }
check() { if [[ "$2" == 0 ]]; then ok "$1"; else fail "$1"; fi; }

# --- refusals
(unset KEYS_DIR; "$scripts/mint-avatar-keys" a) >/dev/null 2>&1; check "mint refuses without KEYS_DIR" "$(( $? == 0 ))"
"$scripts/mint-avatar-keys" ../x >/dev/null 2>&1;                  check "mint refuses a path as a name" "$(( $? == 0 ))"
"$scripts/mint-avatar-keys" --throwaway w >/dev/null 2>&1;         check "--throwaway refuses with fd 3 closed" "$(( $? == 0 ))"
[[ ! -e "$KEYS_DIR/w" ]];                                          check "  and wrote nothing" $?
"$scripts/mint-avatar-keys" --throwaway w v 3>/dev/null >/dev/null 2>&1; check "--throwaway refuses two names" "$(( $? == 0 ))"

# --- full mint: nsec to pass, public halves to files, nothing private on stdout
out="$("$scripts/mint-avatar-keys" a b)"
for n in a b; do
    [[ "$(cat "$T/store/nunet/avatars/$n/nostr-nsec.gpg")" =~ ^[0-9a-f]{64}$ ]]; check "mint $n: nsec in pass" $?
    [[ "$(cat "$KEYS_DIR/$n/nostr-pubkey-hex")" =~ ^[0-9a-f]{64}$ ]];          check "mint $n: pubkey-hex file" $?
    [[ "$(cat "$KEYS_DIR/$n/nostr-npub")" == npub1* ]];                         check "mint $n: npub file" $?
    [[ ! -e "$T/store/nunet/avatars/$n/nostr-pubkey-hex.gpg" && ! -e "$T/store/nunet/avatars/$n/nostr-npub.gpg" ]]
    check "mint $n: no public entries in pass" $?
    ! grep -qF "$(cat "$T/store/nunet/avatars/$n/nostr-nsec.gpg")" <<<"$out";   check "mint $n: nsec not printed" $?
done
[[ "$(sha256sum < <(tr -d '\n' < "$T/store/nunet/avatars/a/nostr-nsec.gpg") | cut -c1-64)" == "$(cat "$KEYS_DIR/a/nostr-pubkey-hex")" ]]
check "mint a: the file holds the stored key's public half" $?

# --- throwaway: nsec only on fd 3
sk="$("$scripts/mint-avatar-keys" --throwaway w 3>&1 >/dev/null)"
[[ "$sk" =~ ^[0-9a-f]{64}$ ]];                                      check "--throwaway: nsec on fd 3" $?
[[ ! -e "$T/store/nunet/avatars/w" ]];                              check "--throwaway: nothing in pass" $?
[[ "$(printf %s "$sk" | sha256sum | cut -c1-64)" == "$(cat "$KEYS_DIR/w/nostr-pubkey-hex")" ]]
check "--throwaway: public file matches the handed-out key" $?
! grep -rqF "$sk" "$KEYS_DIR" "$T/store";                           check "--throwaway: nsec written nowhere" $?

# --- build-registry from the files
reg="$("$scripts/build-registry" a w)"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["w"]["pubkey_hex"]==sys.argv[2]' "$reg" "$(cat "$KEYS_DIR/w/nostr-pubkey-hex")"
check "build-registry: valid JSON from the files" $?
"$scripts/build-registry" a nobody >/dev/null 2>&1;                 check "build-registry: refuses a name with no files" "$(( $? == 0 ))"
(unset KEYS_DIR; "$scripts/build-registry" a) >/dev/null 2>&1;     check "build-registry: refuses without KEYS_DIR" "$(( $? == 0 ))"

# --- drop: exactly what mint wrote, plus legacy public entries; nothing else
echo tok > "$T/store/nunet/avatars/a/gitlab-token.gpg"
echo old > "$T/store/nunet/avatars/a/nostr-npub.gpg"
"$scripts/drop-avatar-keys" a w >/dev/null
[[ ! -e "$KEYS_DIR/a" && ! -e "$KEYS_DIR/w" ]];                     check "drop: public files gone" $?
[[ ! -e "$T/store/nunet/avatars/a/nostr-nsec.gpg" && ! -e "$T/store/nunet/avatars/a/nostr-npub.gpg" ]]
check "drop: nsec and legacy public entry gone from pass" $?
[[ -e "$T/store/nunet/avatars/a/gitlab-token.gpg" ]];               check "drop: other secrets in the folder kept" $?
[[ -e "$KEYS_DIR/b" && -e "$T/store/nunet/avatars/b/nostr-nsec.gpg" ]]; check "drop: other avatars untouched" $?
"$scripts/drop-avatar-keys" ../b >/dev/null 2>&1;                  check "drop: refuses a path as a name" "$(( $? == 0 ))"

(( fails == 0 )) && echo "all ok" || { echo "$fails failed"; exit 1; }
