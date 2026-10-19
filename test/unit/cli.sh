#!/bin/bash
# The command surface, and the harness itself: stubs stand in for every disk, TPM and boot tool, and record the calls.
source "$(dirname "$0")/lib.sh"
sandbox

echo "[help]"
me_user --help
[[ $RC -eq 0 && $OUT == *"setup"* && $OUT == *"status [--json]"* && $OUT == *"recovery-key"* && $OUT == *"reassert"* ]] \
  && ok "--help lists every command" || bad "--help: rc $RC: $OUT"
me_user; [[ $RC -eq 0 && $OUT == Usage:* ]] && ok "no command prints usage" || bad "no command: rc $RC"
me_user frobnicate; [[ $RC -eq 1 && $OUT == Usage:* ]] && ok "unknown command: usage, exit 1" || bad "unknown: rc $RC"
me_user status --bogus; [[ $RC -eq 1 && $OUT == Usage:* ]] && ok "status refuses unknown options" || bad "status --bogus: rc $RC"

echo "[not implemented yet]"
for args in reassert; do
  # shellcheck disable=SC2086  # word-split on purpose: "status --json" is two arguments
  me $args
  [[ $RC -eq 1 && $OUT == *"${args%% *} is not implemented yet"* ]] && ok "$args: not implemented, exit 1" || bad "$args: rc $RC: $OUT"
done

echo "[root]"
for c in setup recovery-key reassert; do
  me_user "$c"; [[ $RC -eq 1 && $OUT == *"run it with sudo"* ]] && ok "$c without root is refused" || bad "$c as user: $OUT"
done

echo "[package]"
libs=$(sed -n 's|^source "\$ROOT/lib/\([a-z]*\)\.sh"$|\1|p' "$MEBIN")
inst=$(sed -n 's|.*/lib/"{\([a-z,]*\)}\.sh.*|\1|p' "$REPO/packaging/PKGBUILD" | tr , '\n')
missing=$(comm -23 <(sort <<<"$libs") <(sort <<<"$inst"))
[[ -n $libs && -z $missing ]] && ok "the PKGBUILD installs every library the CLI loads" || bad "not packaged: ${missing:-no libraries found}"

echo "[harness]"
for c in cryptsetup sbctl systemd-cryptenroll bootctl limine-update logger; do
  [[ $(command -v "$c") == "$STUBS/$c" ]] && ok "$c resolves to the stub" || bad "$c resolves to $(command -v "$c")"
done
: > "$STUB_LOG"
unshare -r cryptsetup open --test-passphrase /dev/vda2 </dev/null 2>/dev/null
check "a stub records the command line it was given" called "cryptsetup open --test-passphrase /dev/vda2"
me reassert; check "the CLI logs through the logger stub, not the host journal" called "logger -t monarchy-encryption"
result
