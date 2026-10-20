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
DISK_PASSPHRASE=hunter2-sandbox-disk     # the sandbox disk's only key until a suite adds one

# sandbox: a stock Omarchy laptop in a temp dir: the ESP ($T/boot) with Omarchy's limine.conf and boot files; its
# /etc/default/limine, mkinitcpio config (busybox hooks) and crypttab; UEFI ($T/efivars) with Secure Boot off and the
# manufacturer's keys, as Omarchy laptops are; a TPM that systemd-pcrlock can use (its stub); / on /dev/mapper/root,
# LUKS on /dev/vda2 with the passphrase in its only keyslot ($T/state/keyslots, read by the cryptsetup and
# systemd-cryptenroll stubs). $T/var and $T/run stand for /var/lib and /run.
sandbox() {
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  export MONARCHY_ENCRYPTION_ETC="$T/etc" MONARCHY_ENCRYPTION_ROOT="$REPO" HOME="$T/home"
  export MONARCHY_ENCRYPTION_ESP="$T/boot" MONARCHY_ENCRYPTION_EFIVARS="$T/efivars"
  export MONARCHY_ENCRYPTION_TPM="$T/tpmrm0" MONARCHY_ENCRYPTION_PROVISIONING="$T/var/lib/omarchy/provisioning"
  export MONARCHY_ENCRYPTION_PCRLOCK="$STUBS/systemd-pcrlock" MONARCHY_ENCRYPTION_PCRLOCK_DIR="$T/var/lib/pcrlock.d"
  export MONARCHY_ENCRYPTION_POLICY="$T/var/lib/systemd/pcrlock.json" MONARCHY_ENCRYPTION_STATE="$T/var/lib/monarchy-encryption"
  export MONARCHY_ENCRYPTION_RUN="$T/run/monarchy-encryption"
  export STUB_STATE="$T/state" STUB_LOG="$T/calls.log" PATH="$STUBS:$PATH"
  unset STUB_ENROLL_FAIL STUB_LIMINE_UPDATE_FAIL STUB_NOT_LUKS STUB_ROOT_SOURCE STUB_TPM_UNLOCK_FAIL STUB_WIPE_FAIL \
    STUB_RECOVERY_KEY_BROKEN STUB_KEY_UNREADABLE STUB_PCRLOCK_UNPREDICTABLE STUB_PCRLOCK_UNSUPPORTED
  mkdir -p "$T/etc/default" "$T/etc/boot/hooks/post.d" "$T/state" "$T/home" "$T/efivars" \
    "$T/boot/EFI/limine" "$T/boot/EFI/BOOT" "$T/boot/EFI/Linux"
  cp "$FIX/boot/limine.conf" "$T/boot/"; cp "$FIX/etc/default/limine" "$T/etc/default/"
  cp -r "$FIX/etc/mkinitcpio.conf" "$FIX/etc/mkinitcpio.conf.d" "$FIX/etc/crypttab" "$T/etc/"
  echo "Limine 12.9.3 as packaged" > "$T/state/limine-stock.efi"
  cp "$T/state/limine-stock.efi" "$T/boot/EFI/limine/limine_x64.efi"
  cp "$T/state/limine-stock.efi" "$T/boot/EFI/BOOT/BOOTX64.EFI"
  echo "boot image" > "$T/boot/EFI/Linux/omarchy_linux-omarchy.efi"
  efivar SetupMode 0; efivar SecureBoot 0   # how Omarchy laptops come: the manufacturer's keys, Secure Boot off
  echo "0 password $DISK_PASSPHRASE" > "$T/state/keyslots"
  : > "$T/tpmrm0"   # a TPM 2.0
  : > "$STUB_LOG"
}
efivar() { printf "\\x06\\x00\\x00\\x00\\x0$2" > "$T/efivars/$1-$G"; }   # efivar NAME 0|1: a one-byte UEFI variable

# me ARGS...: run the CLI as (fake) root with the disk passphrase on stdin, as a caller gives it; sets OUT
# (stdout+stderr) and RC.
me() { OUT=$(printf '%s\n' "$DISK_PASSPHRASE" | unshare -r "$MEBIN" "$@" 2>&1); RC=$?; }
# me_in INPUT ARGS...: run the CLI as (fake) root with INPUT as one line on stdin; sets OUT (stdout), ERR and RC.
me_in() { local in=$1; shift; OUT=$(printf '%s\n' "$in" | unshare -r "$MEBIN" "$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); rm -f "$T/err"; }
# me_user ARGS...: same, without root (the real uid).
me_user() { OUT=$("$MEBIN" "$@" 2>&1 </dev/null); RC=$?; }
called() { grep -qF -- "$1" "$STUB_LOG"; }   # did a stub see this command line?
snap() { # the machine's state: files' contents, and where links point
  (cd "$T" && find etc boot efivars var run -type f 2>/dev/null | sort | xargs -r md5sum
   find etc boot var -type l -printf '%p -> %l\n' 2>/dev/null | sort)
}
# restart: a new start of the sandbox laptop (/run is empty again), and the boot service that runs at every start
restart() { rm -rf "$T/run"; me_in "" boot; }
js() { jq -r "$1" <<<"$OUT"; }   # js FILTER: a value from the last command's JSON output
