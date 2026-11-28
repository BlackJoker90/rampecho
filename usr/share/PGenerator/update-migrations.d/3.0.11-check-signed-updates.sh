#!/bin/bash
# 3.0.11 (2026-11-28): from this release on the updater installs only signed
# releases, and the root helper gets only PG_CMD from sudo (no SETENV). The
# updater that installs this release is the older one, which checks neither,
# so this migration does it while a failure still rolls the update back:
#  1. the daemon user reaches the root helper with the new sudo rules (PING);
#  2. the new updater's signature check works with this device's openssl and
#     awk: it accepts a valid signature, refuses another key's and a changed
#     file, and its release key list parses.
# Without both the device would be left without a working update path.
# PG_MIGRATION_ROOT: a tree to check instead of / (tests; skips step 1).
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
root=${PG_MIGRATION_ROOT:-}
upd="$root/usr/sbin/pgenerator-update"
fail() { echo "ERROR: $*" >&2; exit 1; }

if [ -z "$root" ]; then
 out=$(su -s /bin/sh pgenerator -c 'PG_CMD=$(printf PING | base64) timeout 20 sudo -n /usr/bin/PGenerator_cmd.pl' 2>&1) || true
 [ "$out" = "OK" ] || fail "the daemon user does not reach the root helper through sudo (answer: ${out:-none})"
 echo "Root helper answers the daemon user through sudo"
fi

command -v openssl >/dev/null 2>&1 || fail "openssl is missing: signed updates cannot be checked"
fn=$(sed -n '/^verify_release_signature() {/,/^}/p' "$upd")
keys=$(sed -n '/^ota_signing_keys() {/,/^}/p' "$upd")
[ -n "$fn" ] && [ -n "$keys" ] || fail "$upd has no signature check"
eval "$fn"
dir=$(mktemp -d "${TMPDIR:-/tmp}/pgen-sig-selftest.XXXXXX") || fail "mktemp failed"
trap 'rm -rf "$dir"' EXIT
printf 'rampecho signature self-test\n' > "$dir/data"
printf '%s' 'MEUCIQDqF7Dym/zCPh35PfT2FlHzZB24E4SU/jZOO/uZRcKcSgIgPSFwr1YVjJ6X/jrm5MuKHxKanrm+ZFxUJUrqfzYWOAU=' | base64 -d > "$dir/good.sig"
printf '%s' 'MEQCIDxibnwVgsMb72i6fDHOo6GWj8Mg5Quevbrhe1cQy9/rAiAoY0gXC6SGba2yUBCZ6DVWl07aoXgnsuQ5DNGZfQV7Gg==' | base64 -d > "$dir/other.sig"
# Throwaway test keys (no private key exists any more): the second signs
# good.sig, the first other.sig. Listed in that order, so the check has to
# get past the first key, as with a key rotation.
ota_signing_keys() {
 cat <<'TESTKEYS'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEqj8OT/AED8L8AI82InH1Qp9ApiYr
TlrErWHuhlk+vSj/79mXv8I5jXgjQWBL8Z0biq39ifv24FsTBCba8jKOgQ==
-----END PUBLIC KEY-----
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEmoKk3qZiL2bqzKLhfnIailuZWq/u
cDPvFLdxFGlJ57ULzveCkMXOzSFnbmw+h4iJ0HkryywAU1hYUMZnCz2sJQ==
-----END PUBLIC KEY-----
TESTKEYS
}
verify_release_signature "$dir/data" "$dir/good.sig" || fail "the signature check refuses a valid signature"
ota_signing_keys() {
 cat <<'ONEKEY'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEmoKk3qZiL2bqzKLhfnIailuZWq/u
cDPvFLdxFGlJ57ULzveCkMXOzSFnbmw+h4iJ0HkryywAU1hYUMZnCz2sJQ==
-----END PUBLIC KEY-----
ONEKEY
}
verify_release_signature "$dir/data" "$dir/other.sig" && fail "the signature check accepts another key's signature"
printf 'x' >> "$dir/data"
verify_release_signature "$dir/data" "$dir/good.sig" && fail "the signature check accepts a changed file"

# The release keys the new updater lists: each one must parse.
eval "$keys"
n=0
while IFS= read -r line; do
 case "$line" in
  "-----BEGIN PUBLIC KEY-----") pem="$line"$'\n' ;;
  "-----END PUBLIC KEY-----")
   pem="$pem$line"$'\n'
   printf '%s' "$pem" | openssl pkey -pubin -noout 2>/dev/null || fail "release key $((n+1)) does not parse"
   n=$((n+1)) ;;
  *) pem="${pem:-}$line"$'\n' ;;
 esac
done < <(ota_signing_keys)
[ "$n" -ge 1 ] || fail "the updater lists no release key"
echo "Signature check works here ($n release key(s))"
