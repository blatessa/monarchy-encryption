#!/bin/bash
# Lab: setup's Secure Boot part on a clean install, then what only the real firmware can show. Starts from the installed
# checkpoint and leaves it with Secure Boot on. About 5 minutes.
source "$(dirname "$0")/lib.sh"
fail=0
ok()  { printf '  PASS %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
shots=$LAB/e2e-secureboot; menu_text() { screenshot "$LAB" "$shots/m.png"; tesseract "$shots/m.png" - 2>/dev/null; }
reboot_vm() { lab_reboot "$LAB"; }
st() { lab_ssh_root monarchy-encryption status --json | jq -r "$1"; }

checkpoint installed build_installed; mkdir -p "$shots"
lab_ssh_root bash -c 'snapper -c root create -d before-setup && limine-snapper-sync' >/dev/null 2>&1

echo "[setup]"
out=$(root_with "$LAB_PASSWORD" "monarchy-encryption setup" 2>&1) && ok "setup succeeds" || { bad "setup failed"; sed 's/^/      /' <<<"$out"; }
[[ $out == *"1 boot image(s) of snapshots taken before Secure Boot"* ]] && ok "it says the snapshot from before can't start from the menu" || bad "no snapshot note: $out"
[[ $(st '[.secure_boot.own_keys, .secure_boot.microsoft_keys, .boot_menu.editor_locked, .boot_menu.config_protected, .boot_menu.fallback_protected] | map(tostring) | join(" ")') == "true true true true true" ]] \
  && ok "status: own and Microsoft keys, menu locked and protected, fallback protected" || bad "status: $(lab_ssh_root monarchy-encryption status --json)"
# the only unsigned file allowed is the boot image of the snapshot taken before setup
unsigned() { lab_ssh_root sbctl verify 2>&1 | grep '✗' | grep -v '/limine_history/' || true; }
[[ -z $(unsigned) ]] && ok "every EFI file on the ESP is signed (but the old snapshot's)" || bad "unsigned: $(unsigned)"

echo "[first start with our keys]"
reboot_vm
[[ $(st .secure_boot.enabled) == true ]] && ok "Secure Boot is on and the laptop starts" || bad "Secure Boot not on: $(st .secure_boot)"
out=$(root_with "$LAB_PASSWORD" "monarchy-encryption setup" 2>&1) && ok "setup's second run succeeds (it enrolls the TPM: e2e-tpm.sh)" || bad "setup rerun: $out"

echo "[the boot menu]"
lab_ssh_root systemctl reboot >/dev/null 2>&1 || true
for _ in $(seq 60); do sleep 0.5; menu_text | grep -qi "Booting automatically" && break; done
press "$LAB" down; sleep 0.3; press "$LAB" up; sleep 0.3
text=$(menu_text)
[[ $text == *"ENTER"* && $text != *"Edit"* && $text != *"Blank Entry"* ]] && ok "the menu offers no Edit and no Blank Entry" || bad "menu: $text"
press "$LAB" e; sleep 1; press "$LAB" b; sleep 1
[[ $(menu_text) != *"cmdline"* ]] && ok "pressing e and b opens no editor" || bad "an editor opened"
screenshot "$LAB" "$shots/menu.png"; press "$LAB" ret; sleep 3; unlock_and_wait "$LAB" 300

echo "[an unsigned EFI program]"
lab_ssh_root bash -c 'mkdir -p /boot/EFI/unsigned && cp /usr/share/limine/BOOTX64.EFI /boot/EFI/unsigned/test.efi &&
  efibootmgr -q -c -d /dev/vda -p 1 -l "\EFI\unsigned\test.efi" -L unsigned-test &&
  efibootmgr -q -n "$(efibootmgr | sed -n "s/^Boot\([0-9A-F]*\)\* unsigned-test.*/\1/p")"'
reboot_vm
cur=$(lab_ssh_root efibootmgr | sed -n 's/^BootCurrent: //p'); next=$(lab_ssh_root efibootmgr | sed -n 's/^BootNext: //p')
name=$(lab_ssh_root efibootmgr | sed -n "s/^Boot$cur\* \([^\t]*\).*/\1/p")
[[ -z $next && $name == Limine ]] && ok "the firmware skipped it and started Limine" || bad "BootCurrent $cur ($name), BootNext '$next'"
lab_ssh_root bash -c 'efibootmgr -q -b "$(efibootmgr | sed -n "s/^Boot\([0-9A-F]*\)\* unsigned-test.*/\1/p")" -B; rm -r /boot/EFI/unsigned'

echo "[a kernel update]"
lab_ssh_root env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --noconfirm linux-omarchy >/dev/null 2>&1
[[ -z $(unsigned) ]] && ok "everything still signed after the kernel package is reinstalled" || bad "unsigned after update: $(unsigned)"
[[ $(st '[.boot_menu.config_protected, .boot_menu.fallback_protected] | map(tostring) | join(" ")') == "true true" ]] \
  && ok "menu and fallback still protected" || bad "after update: $(st .boot_menu)"
reboot_vm && ok "and it starts"

echo "[a snapshot taken with Secure Boot on]"
lab_ssh_root bash -c 'snapper -c root create -d after-setup && limine-snapper-sync' >/dev/null 2>&1
lab_ssh_root systemctl reboot >/dev/null 2>&1 || true
for _ in $(seq 60); do sleep 0.5; menu_text | grep -qi "Booting automatically" && break; done
# Snapshots > newest first: down to Snapshots, open it, open the newest, its kernel
press "$LAB" down; sleep 0.4; press "$LAB" ret; sleep 0.4; press "$LAB" down; sleep 0.4; press "$LAB" ret; sleep 0.4
press "$LAB" down; sleep 0.4; screenshot "$LAB" "$shots/snapshot-menu.png"; press "$LAB" ret; sleep 3
if (unlock_and_wait "$LAB" 300) 2>/dev/null && [[ $(lab_ssh 'findmnt -no FSTYPE /') == overlay ]]; then ok "it starts from the boot menu"
else screenshot "$LAB" "$shots/snapshot.png"; bad "snapshot didn't start (screen: $shots/snapshot.png, menu: $shots/snapshot-menu.png)"
  qmp "$LAB" '"system_reset"' >/dev/null; sleep 3; unlock_and_wait "$LAB" 300; fi
reboot_vm

echo "[a changed boot menu]"
lab_ssh_root sed -i 's/^editor_enabled: no$/editor_enabled: yes/' /boot/limine.conf
lab_ssh_root systemctl reboot >/dev/null 2>&1 || true
halted=""; for _ in $(seq 40); do sleep 1; t=$(menu_text); [[ $t == *"CHECKSUM MISMATCH"* ]] && { halted=1; break; }; done
[[ -n $halted ]] && ok "Limine refuses to start a changed menu" || { screenshot "$LAB" "$shots/tamper.png"; bad "no checksum panic (screen: $shots/tamper.png)"; }
qmp "$LAB" '"quit"' >/dev/null

((fail)) && { echo "RESULT: FAIL"; exit 1; }
echo "RESULT: ALL PASS (the lab VM is stopped; its menu was changed on purpose: test/vm/reset.sh)"
