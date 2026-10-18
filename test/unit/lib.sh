# Harness for the fast layer: the real CLI against a temp /etc with stub commands first on PATH, as root inside a
# user namespace (`unshare -r`). No VM, no real root. Source it: `source "$(dirname "$0")/lib.sh"`.
# Stubs live in stubs/ (their behaviour and where it was observed: docs/dev/findings.md). Every suite ends with `result`.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUBS="$REPO/test/unit/stubs"
MEBIN="$REPO/bin/monarchy-encryption"
fail=0
ok()  { printf '  PASS %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
check() { local desc=$1; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }   # check DESC CMD...
result() { ((fail)) && { echo "RESULT: FAIL"; exit 1; }; echo "RESULT: ALL PASS"; }
unshare -r true 2>/dev/null || { echo "SKIP: 'unshare -r' is not allowed here (user namespaces disabled)"; exit 1; }

FIX="$REPO/test/unit/fixtures"
G=8be4df61-93ca-11d2-aa0d-00e098032b8c   # UEFI global variables

# sandbox: a stock Omarchy laptop in a temp dir: the ESP ($T/boot) with Omarchy's limine.conf and boot files, its
# /etc/default/limine, and firmware variables ($T/efivars) in setup mode with Secure Boot off and no keys.
sandbox() {
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  export MONARCHY_ENCRYPTION_ETC="$T/etc" MONARCHY_ENCRYPTION_ROOT="$REPO" HOME="$T/home"
  export MONARCHY_ENCRYPTION_ESP="$T/boot" MONARCHY_ENCRYPTION_EFIVARS="$T/efivars" MONARCHY_ENCRYPTION_SBCTL_DIR="$T/sbctl"
  export STUB_STATE="$T/state" STUB_LOG="$T/calls.log" PATH="$STUBS:$PATH"
  unset STUB_ENROLL_FAIL STUB_LIMINE_UPDATE_FAIL STUB_UKI_UNSIGNED
  mkdir -p "$T/etc/default" "$T/etc/boot/hooks/post.d" "$T/state" "$T/home" "$T/efivars" \
    "$T/boot/EFI/limine" "$T/boot/EFI/BOOT" "$T/boot/EFI/Linux"
  cp "$FIX/boot/limine.conf" "$T/boot/"; cp "$FIX/etc/default/limine" "$T/etc/default/"
  echo "Limine 12.9.3 as packaged" > "$T/state/limine-stock.efi"
  cp "$T/state/limine-stock.efi" "$T/boot/EFI/limine/limine_x64.efi"
  cp "$T/state/limine-stock.efi" "$T/boot/EFI/BOOT/BOOTX64.EFI"
  echo "boot image" > "$T/boot/EFI/Linux/omarchy_linux-omarchy.efi"
  efivar SetupMode 1; efivar SecureBoot 0
  : > "$STUB_LOG"
}
efivar() { printf "\\x06\\x00\\x00\\x00\\x0$2" > "$T/efivars/$1-$G"; }   # efivar NAME 0|1: a one-byte UEFI variable

# me ARGS...: run the CLI as (fake) root; sets OUT (stdout+stderr) and RC.
me() { OUT=$(unshare -r "$MEBIN" "$@" 2>&1 </dev/null); RC=$?; }
# me_user ARGS...: same, without root (the real uid).
me_user() { OUT=$("$MEBIN" "$@" 2>&1 </dev/null); RC=$?; }
called() { grep -qF -- "$1" "$STUB_LOG"; }   # did a stub see this command line?
snap() { (cd "$T" && find etc boot efivars sbctl -type f 2>/dev/null | sort | xargs -r md5sum); }   # the machine's state
js() { jq -r "$1" <<<"$OUT"; }   # js FILTER: a value from the last command's JSON output
