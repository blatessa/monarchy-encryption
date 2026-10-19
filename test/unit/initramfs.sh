#!/bin/bash
# setup's systemd initramfs: the mkinitcpio drop-in's mapping of Omarchy's busybox hooks, the crypttab line, refusals
# that change nothing, re-running that changes nothing, and status.
source "$(dirname "$0")/lib.sh"

# hooks_with FILE...: the HOOKS mkinitcpio would use, sourcing these files in order (as mkinitcpio does)
hooks_with() { (set +u; HOOKS=() FILES=() MODULES=(); for f in "$@"; do source "$f"; done; echo "${HOOKS[*]}"); }
DROPIN="$REPO/data/zz-monarchy-encryption.conf"
OMARCHY=("$FIX/etc/mkinitcpio.conf" "$FIX/etc/mkinitcpio.conf.d/omarchy_hooks.conf" "$FIX/etc/mkinitcpio.conf.d/omarchy_resume.conf")
has() { [[ " $1 " == *" $2 "* ]]; }

echo "[the drop-in's mapping]"
# FILES decides sd-vconsole; set it here rather than through Omarchy's own check, which reads the host's /etc/vconsole.conf
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
printf 'FILES=(/etc/vconsole.conf)\n' > "$t/latin.conf"; printf 'FILES=()\n' > "$t/non-latin.conf"
h=$(hooks_with "${OMARCHY[@]}" "$t/latin.conf" "$DROPIN")
[[ $h == "base systemd plymouth keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems fsck sd-btrfs-overlayfs" ]] \
  && ok "Omarchy's hooks, each busybox one swapped for its systemd counterpart, in Omarchy's order" || bad "hooks: $h"
h=$(hooks_with "${OMARCHY[@]}" "$t/non-latin.conf" "$DROPIN")
! has "$h" sd-vconsole && ! has "$h" keymap && has "$h" keyboard \
  && ok "a non-Latin layout stays out of the initramfs, so the passphrase stays typeable" || bad "non-Latin: $h"
mkdir -p "$t/pci/0000:01:00.0"; echo 0x030000 > "$t/pci/0000:01:00.0/class"; echo 0x10de > "$t/pci/0000:01:00.0/vendor"
printf 'MODULES+=(nvidia_drm)\n' > "$t/nvidia.conf"
h=$(OMARCHY_PCI_DEVICES_PATH="$t/pci" hooks_with "$FIX/etc/mkinitcpio.conf" "$t/nvidia.conf" "${OMARCHY[@]:1}" "$DROPIN")
! has "$h" kms && has "$h" sd-encrypt && ok "an NVIDIA-only laptop keeps Omarchy's decision to drop kms" || bad "nvidia: $h"
printf 'HOOKS=(base udev block encrypt omarchy-future filesystems)\nFILES=()\n' > "$t/future.conf"
h=$(hooks_with "$t/future.conf" "$DROPIN")
[[ $h == "base systemd block sd-encrypt omarchy-future filesystems" ]] && ok "a hook it doesn't know is kept where Omarchy put it" || bad "future: $h"
h=$(hooks_with "${OMARCHY[@]}" "$t/latin.conf" "$DROPIN" "$DROPIN")
[[ $h == "base systemd plymouth keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems fsck sd-btrfs-overlayfs" ]] \
  && ok "applying it twice changes nothing" || bad "twice: $h"

echo "[setup on a stock install]"
sandbox
me status --json
[[ $(js '[.disk.encrypted, .disk.systemd_initramfs] | map(tostring) | join(" ")') == "true false" ]] && ok "status before: encrypted, busybox initramfs" || bad "status before: $OUT"
me setup
[[ $RC -eq 0 ]] && ok "setup succeeds" || { bad "setup: rc $RC"; sed 's/^/      /' <<<"$OUT"; }
check "the drop-in is installed as packaged" cmp -s "$DROPIN" "$T/etc/mkinitcpio.conf.d/zz-monarchy-encryption.conf"
[[ $(grep -v '^#' "$T/etc/crypttab" | grep .) == "root  UUID=8b81edbd-cf38-4664-82ab-17852814fdb0  none  luks,x-initrd.attach" ]] \
  && ok "crypttab opens the LUKS partition under / as 'root' in the initramfs" || bad "crypttab: $(grep -v '^#' "$T/etc/crypttab")"
check "Omarchy's crypttab comments are kept" grep -q '^# <name>' "$T/etc/crypttab"
check "the boot image was rebuilt (and signed)" called "limine-update"
me status --json
[[ $(js '[.disk.encrypted, .disk.systemd_initramfs] | map(tostring) | join(" ")') == "true true" ]] && ok "status after: systemd initramfs" || bad "status after: $OUT"

echo "[setup again]"
: > "$STUB_LOG"; BEFORE=$(snap); me setup
[[ $RC -eq 0 && $(snap) == "$BEFORE" ]] && ok "re-running changes nothing" || bad "rerun: rc $RC, changed: $(diff <(echo "$BEFORE") <(snap))"
called "limine-update" && bad "boot image rebuilt for nothing" || ok "and doesn't rebuild the boot image"
rm "$T/etc/mkinitcpio.conf.d/zz-monarchy-encryption.conf"; : > "$STUB_LOG"; me setup
[[ $RC -eq 0 && -f $T/etc/mkinitcpio.conf.d/zz-monarchy-encryption.conf ]] && called "limine-update" \
  && ok "a removed drop-in is put back and the boot image rebuilt" || bad "drop-in not restored: $OUT"

echo "[refused, nothing changed]"
sandbox; export STUB_NOT_LUKS=1 STUB_ROOT_SOURCE=/dev/vda2; BEFORE=$(snap); me setup
[[ $RC -ne 0 && $OUT == *"isn't encrypted"* && $(snap) == "$BEFORE" ]] && ok "an unencrypted disk: refused, nothing changed" || bad "not LUKS: rc $RC: $OUT"
unset STUB_NOT_LUKS STUB_ROOT_SOURCE
me status --json; [[ $(js .disk.encrypted) == true ]] && ok "status: encrypted" || bad "$OUT"

sandbox; echo "root  /dev/vda2  /etc/keyfile  luks" >> "$T/etc/crypttab"; BEFORE=$(snap); me setup
[[ $RC -ne 0 && $OUT == *"describes the disk 'root' differently"* && $(snap) == "$BEFORE" ]] && ok "crypttab already says something else about the disk: refused, nothing changed" || bad "conflict: rc $RC: $OUT"

sandbox; efivar SetupMode 0; { printf '\x27\x00\x00\x00'; echo "someone else's key"; } > "$T/efivars/PK-$G"; BEFORE=$(snap); me setup
[[ $RC -ne 0 && $(snap) == "$BEFORE" ]] && ok "someone else's Secure Boot keys: the initramfs is left alone too" || bad "foreign keys changed the initramfs"

echo "[an existing line that says the same]"
sandbox; echo "root  UUID=8b81edbd-cf38-4664-82ab-17852814fdb0  none  luks,x-initrd.attach,discard" >> "$T/etc/crypttab"; me setup
[[ $RC -eq 0 && $(grep -c '^root ' "$T/etc/crypttab") == 1 ]] && ok "accepted and not duplicated (its own options kept)" || bad "same line: rc $RC: $OUT"

echo "[hibernation after an Omarchy factory reset: resume= names no device]"
sandbox; mkdir -p "$T/etc/limine-entry-tool.d"
echo 'KERNEL_CMDLINE[default]+=" resume= resume_offset=4035724"' > "$T/etc/limine-entry-tool.d/resume.conf"
me setup
[[ $RC -eq 0 && $(grep -v '^#' "$T/etc/limine-entry-tool.d/00-monarchy-encryption.conf") == 'KERNEL_CMDLINE[default]+=" resume=/dev/mapper/root"' ]] \
  && ok "a drop-in names the device, sorted to land last on the command line" || bad "resume drop-in: rc $RC: $(cat "$T/etc/limine-entry-tool.d/00-monarchy-encryption.conf" 2>&1)"
check "Omarchy's own resume.conf is left as it is" grep -qx 'KERNEL_CMDLINE\[default\]+=" resume= resume_offset=4035724"' "$T/etc/limine-entry-tool.d/resume.conf"
: > "$STUB_LOG"; me setup; called "limine-update" && bad "rebuilt again for nothing" || ok "setup again: nothing to do"
for c in 'resume=/dev/mapper/root resume_offset=4035724' 'rtc_cmos.use_acpi_alarm=1'; do
  sandbox; mkdir -p "$T/etc/limine-entry-tool.d"; echo "KERNEL_CMDLINE[default]+=\" $c\"" > "$T/etc/limine-entry-tool.d/resume.conf"
  me setup; [[ $RC -eq 0 && ! -e $T/etc/limine-entry-tool.d/00-monarchy-encryption.conf ]] && ok "no drop-in with \"$c\"" || bad "drop-in written for \"$c\""
done

echo "[status without root]"
sandbox; me_user status --json
[[ $(js '[.disk.encrypted, .disk.systemd_initramfs] | map(tostring) | join(" ")') == "null null" ]] && ok "null, not a guess" || bad "user: $OUT"
result
