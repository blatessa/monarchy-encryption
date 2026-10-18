#!/bin/bash
# setup's Secure Boot part: own keys, everything signed before they go in, a boot menu that can't be edited or
# swapped, refusals that change nothing, and status --json following the machine.
source "$(dirname "$0")/lib.sh"

line_of() { grep -n -F -- "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }   # first line in the call log with this text

echo "[setup on a laptop in setup mode]"
sandbox
me setup
[[ $RC -eq 0 ]] && ok "setup succeeds" || { bad "setup: rc $RC"; sed 's/^/      /' <<<"$OUT"; }
check "keys created" test -f "$T/sbctl/keys/PK/PK.pem"
check "keys enrolled with Microsoft's kept (devices start Microsoft-signed firmware)" called "sbctl enroll-keys --microsoft"
s=$(line_of "limine-update"); e=$(line_of "sbctl enroll-keys")
[[ -n $s && -n $e && $s -lt $e ]] && ok "everything is signed before the keys go into the firmware" || bad "order: sign line $s, enroll line $e"
[[ $(head -2 "$T/boot/limine.conf" | tail -1) == "editor_enabled: no" ]] && ok "boot menu editor off, above the entries" || bad "editor line: $(grep -n editor "$T/boot/limine.conf")"
check "menu checksum enrollment on in /etc/default/limine" grep -qx 'ENABLE_ENROLL_LIMINE_CONFIG=yes' "$T/etc/default/limine"
[[ $(readlink "$T/etc/boot/hooks/post.d/95-monarchy-encryption-fallback") == "$REPO/hooks/limine-fallback" ]] \
  && ok "fallback hook linked after Limine's enroll hook" || bad "hook link"
check "the fallback loader is the enrolled Limine, not the plain one" cmp -s "$T/boot/EFI/limine/limine_x64.efi" "$T/boot/EFI/BOOT/BOOTX64.EFI"
grep -q "^enrolled $(b2sum "$T/boot/limine.conf" | cut -d' ' -f1)$" "$T/boot/EFI/limine/limine_x64.efi" \
  && ok "Limine carries the checksum of the menu as written (editor line included)" || bad "enrolled checksum"
me status --json
[[ $(js '[.schema, .secure_boot.setup_mode, .secure_boot.own_keys, .secure_boot.microsoft_keys] | @tsv') == $'1\tfalse\ttrue\ttrue' ]] \
  && ok "status: our keys and Microsoft's enrolled, out of setup mode" || bad "status: $OUT"
[[ $(js '.boot_menu | [.editor_locked, .config_protected, .fallback_protected] | @tsv') == $'true\ttrue\ttrue' ]] \
  && ok "status: menu locked, protected, fallback protected" || bad "boot_menu: $OUT"
[[ $(js .secure_boot.enabled) == false ]] && ok "status: Secure Boot not on until the next start" || bad "enabled: $OUT"

echo "[setup again]"
: > "$STUB_LOG"; before_editor=$(grep -c '^editor_enabled' "$T/boot/limine.conf")
me setup
[[ $RC -eq 0 ]] && ok "re-running succeeds with our keys already in the firmware" || bad "rerun: rc $RC: $OUT"
called "sbctl enroll-keys" && bad "enrolled again" || ok "keys not enrolled again"
called "sbctl create-keys" && bad "keys created again" || ok "keys not created again"
[[ $(grep -c '^editor_enabled' "$T/boot/limine.conf") == "$before_editor" && $(grep -c '^ENABLE_ENROLL' "$T/etc/default/limine") == 1 ]] \
  && ok "no duplicated settings" || bad "duplicates"
efivar SecureBoot 1; me status --json
[[ $(js .secure_boot.enabled) == true ]] && ok "status follows the firmware: Secure Boot on" || bad "enabled after start: $OUT"

echo "[refused, nothing changed]"
sandbox; rm -f "$T/efivars/SetupMode-$G"; efivar SetupMode 0
{ printf '\x27\x00\x00\x00'; echo "a manufacturer's platform key"; } > "$T/efivars/PK-$G"
BEFORE=$(snap); me setup
[[ $RC -ne 0 && $OUT == *"keys that aren't this laptop's own"* ]] && ok "someone else's keys: refused with how to fix it" || bad "foreign keys: rc $RC: $OUT"
[[ $(snap) == "$BEFORE" ]] && ok "someone else's keys: nothing changed" || bad "foreign keys: machine changed"

sandbox; rm -rf "$T/efivars"; BEFORE=$(snap); me setup
[[ $RC -ne 0 && $OUT == *"UEFI"* && $(snap) == "$BEFORE" ]] && ok "not started in UEFI mode: refused, nothing changed" || bad "no UEFI: rc $RC: $OUT"

sandbox; rm "$T/boot/limine.conf"; me setup
[[ $RC -ne 0 && $OUT == *"no Limine menu"* ]] && ok "no Limine menu: refused" || bad "no limine.conf: rc $RC: $OUT"

sandbox; export STUB_UKI_UNSIGNED=1; me setup
[[ $RC -ne 0 && $OUT == *"still unsigned"*"omarchy_linux-omarchy.efi"* ]] && ok "a boot image left unsigned: refused, naming it" || bad "unsigned: rc $RC: $OUT"
called "sbctl enroll-keys" && bad "keys enrolled although a boot file is unsigned" || ok "keys not enrolled, so the laptop still starts"
unset STUB_UKI_UNSIGNED

sandbox; export STUB_LIMINE_UPDATE_FAIL=1; me setup
[[ $RC -ne 0 && $OUT == *"limine-update"* && $OUT == *"Failed to build"* ]] && ok "signing fails: refused, with the tool's error" || bad "limine-update fail: rc $RC: $OUT"
called "sbctl enroll-keys" && bad "enrolled after a failed signing" || ok "keys not enrolled"
unset STUB_LIMINE_UPDATE_FAIL

sandbox; me_user setup; [[ $RC -ne 0 && $OUT == *"sudo"* ]] && ok "needs root" || bad "as user: $OUT"

echo "[Omarchy's own settings]"
sandbox
sed -i '1i editor_enabled: yes' "$T/boot/limine.conf"; echo 'ENABLE_ENROLL_LIMINE_CONFIG=no' >> "$T/etc/default/limine"
me setup
[[ $(grep -c '^editor_enabled' "$T/boot/limine.conf") == 1 ]] && check "an existing editor setting is switched off, not duplicated" grep -qx 'editor_enabled: no' "$T/boot/limine.conf" || bad "editor duplicated"
[[ $(grep -c '^ENABLE_ENROLL' "$T/etc/default/limine") == 1 ]] && check "an existing enroll setting is switched on, not duplicated" grep -qx 'ENABLE_ENROLL_LIMINE_CONFIG=yes' "$T/etc/default/limine" || bad "enroll duplicated"
check "the rest of /etc/default/limine is untouched" grep -qF 'KERNEL_CMDLINE[default]+="cryptdevice=' "$T/etc/default/limine"

echo "[snapshots taken before setup]"
sandbox; mkdir -p "$T/boot/cb82a78dc7ae41bcb54de29f52045d07/limine_history"
echo "old boot image" > "$T/boot/cb82a78dc7ae41bcb54de29f52045d07/limine_history/omarchy_linux-omarchy.efi_sha256_3ecb"
me setup
[[ $RC -eq 0 && $OUT == *"1 boot image(s) of snapshots taken before Secure Boot"* ]] && ok "setup goes ahead and says which snapshots won't start" || bad "snapshot note: rc $RC: $OUT"
check "keys still enrolled (an old snapshot isn't a reason to stop)" called "sbctl enroll-keys"
check "the old snapshot image is left as it is (its hash is pinned)" grep -qx "old boot image" "$T/boot/cb82a78dc7ae41bcb54de29f52045d07/limine_history/omarchy_linux-omarchy.efi_sha256_3ecb"
sandbox; me setup; [[ $OUT != *"snapshots taken before"* ]] && ok "no note without old snapshots" || bad "spurious note: $OUT"

echo "[the fallback hook]"
cp "$T/state/limine-stock.efi" "$T/boot/EFI/BOOT/BOOTX64.EFI"   # what limine-install does on every update
unshare -r "$T/etc/boot/hooks/post.d/95-monarchy-encryption-fallback" && cmp -s "$T/boot/EFI/limine/limine_x64.efi" "$T/boot/EFI/BOOT/BOOTX64.EFI" \
  && ok "replaces a plain fallback with the enrolled Limine" || bad "hook didn't replace the fallback"
me status --json; [[ $(js .boot_menu.fallback_protected) == true ]] && ok "status: fallback protected again" || bad "fallback status"
cp "$T/state/limine-stock.efi" "$T/boot/EFI/BOOT/BOOTX64.EFI"; me status --json
[[ $(js .boot_menu.fallback_protected) == false ]] && ok "status notices a plain fallback" || bad "plain fallback unnoticed"
echo "editor_enabled: yes" >> "$T/boot/limine.conf"; me status --json
[[ $(js .boot_menu.config_protected) == false ]] && ok "status notices a menu changed since it was enrolled" || bad "changed menu unnoticed"

echo "[status without root]"
me_user status --json
[[ $(js '[.secure_boot.own_keys, .boot_menu.editor_locked, .boot_menu.config_protected] | map(tostring) | @tsv') == $'null\tnull\tnull' ]] \
  && ok "what only root can check is null, not a guess" || bad "user status: $OUT"
me_user status; [[ $RC -eq 0 && $OUT == *"Secure Boot:"* && $OUT == *"unknown (run as root)"* ]] && ok "plain status" || bad "plain: $OUT"
result
