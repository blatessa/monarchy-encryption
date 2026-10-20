#!/bin/bash
# The command surface, and the harness itself: stubs stand in for every disk, TPM and boot tool, and record the calls.
source "$(dirname "$0")/lib.sh"
sandbox

echo "[help]"
me_user --help
[[ $RC -eq 0 && $OUT == *"setup"* && $OUT == *"status [--json]"* && $OUT == *"recovery-key"* && $OUT == *"reassert"* && $OUT == *"boot"* && $OUT == *"release"* ]] \
  && ok "--help lists every command" || bad "--help: rc $RC: $OUT"
me_user; [[ $RC -eq 0 && $OUT == Usage:* ]] && ok "no command prints usage" || bad "no command: rc $RC"
me_user frobnicate; [[ $RC -eq 1 && $OUT == Usage:* ]] && ok "unknown command: usage, exit 1" || bad "unknown: rc $RC"
me_user status --bogus; [[ $RC -eq 1 && $OUT == Usage:* ]] && ok "status refuses unknown options" || bad "status --bogus: rc $RC"

echo "[root]"
for c in setup recovery-key reassert release boot; do
  me_user "$c"; [[ $RC -eq 1 && $OUT == *"run it with sudo"* ]] && ok "$c without root is refused" || bad "$c as user: $OUT"
done

echo "[package]"
libs=$(sed -n 's|^source "\$ROOT/lib/\([a-z]*\)\.sh"$|\1|p' "$MEBIN")
inst=$(sed -n 's|.*/lib/"{\([a-z,]*\)}\.sh.*|\1|p' "$REPO/packaging/PKGBUILD" | tr , '\n')
missing=$(comm -23 <(sort <<<"$libs") <(sort <<<"$inst"))
[[ -n $libs && -z $missing ]] && ok "the PKGBUILD installs every library the CLI loads" || bad "not packaged: ${missing:-no libraries found}"
for h in "$REPO"/hooks/*; do
  grep -qF "\"\$_root/hooks/${h##*/}\"" "$REPO/packaging/PKGBUILD" || bad "hooks/${h##*/} isn't installed by the PKGBUILD"
done; ok "the PKGBUILD installs every hook"
grep -qF '"$_root/packaging/monarchy-encryption-boot.service" "$pkgdir/usr/lib/systemd/system/monarchy-encryption-boot.service"' "$REPO/packaging/PKGBUILD" \
  && grep -qF 'ln -sfn "/usr/lib/systemd/system/$BOOT_UNIT"' "$REPO/lib/tpm.sh" && grep -qx 'BOOT_UNIT=monarchy-encryption-boot.service' "$REPO/lib/pcrlock.sh" \
  && ok "the PKGBUILD installs the boot service where setup links it from" || bad "boot service not installed where setup links it from"
grep -q 'sbctl' "$REPO/packaging/PKGBUILD" && bad "sbctl is still a dependency" || ok "no Secure Boot tooling needed"

echo "[harness]"
for c in cryptsetup systemd-cryptenroll bootctl limine-update logger; do
  [[ $(command -v "$c") == "$STUBS/$c" ]] && ok "$c resolves to the stub" || bad "$c resolves to $(command -v "$c")"
done
[[ $MONARCHY_ENCRYPTION_PCRLOCK == "$STUBS/systemd-pcrlock" ]] && ok "systemd-pcrlock (not on PATH) is the stub" || bad "pcrlock: $MONARCHY_ENCRYPTION_PCRLOCK"
: > "$STUB_LOG"
unshare -r cryptsetup open --test-passphrase /dev/vda2 </dev/null 2>/dev/null
check "a stub records the command line it was given" called "cryptsetup open --test-passphrase /dev/vda2"
me reassert; check "the CLI logs through the logger stub, not the host journal" called "logger -t monarchy-encryption"
result
