#!/bin/bash
# Lab: setup's boot part on a clean install, then what only real firmware and a real TPM can show: the TPM opens the
# disk for this laptop's boot files and nothing else (a plain Limine, a snapshot with an older boot image, a changed
# menu), and follows them through updates and snapshots. Starts from the installed checkpoint. About 10 minutes.
source "$(dirname "$0")/lib.sh"
fail=0
ok()  { printf '  PASS %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
shots=$LAB/e2e-boot; menu_text() { screenshot "$LAB" "$shots/m.png"; tesseract "$shots/m.png" - 2>/dev/null; }
st() { lab_ssh_root monarchy-encryption status --json | jq -c "$1"; }
pk() { lab_ssh_root bash -c 'md5sum /sys/firmware/efi/efivars/{PK,KEK,db,dbx}-* 2>/dev/null; true'; }
# untyped NAME: restart, expecting nothing typed; else type the recovery key and say so
untyped() { restart_untyped && return 0; screenshot "$LAB" "$shots/$1.png"; unlock_and_wait "$LAB" 300 "$key"; return 1; }
# prompted NAME: the start the VM is in waits at the disk prompt (nothing typed for 90 s); then the recovery key opens it
prompted() {
  if up_untyped 90; then return 1; fi
  screenshot "$LAB" "$shots/$1.png"; unlock_and_wait "$LAB" 300 "$key"
}
# to_snapshot N: restart into the boot menu's Nth newest snapshot
to_snapshot() {
  lab_ssh_root systemctl reboot >/dev/null 2>&1 || true
  for _ in $(seq 60); do sleep 0.5; menu_text | grep -qi "Booting automatically" && break; done
  press "$LAB" down; sleep 0.4; press "$LAB" ret; sleep 0.4                    # Snapshots
  for _ in $(seq "$1"); do press "$LAB" down; sleep 0.4; done; press "$LAB" ret; sleep 0.4
  press "$LAB" down; sleep 0.4; screenshot "$LAB" "$shots/snapshot-menu-$1.png"; press "$LAB" ret; sleep 3
}
rebuild() { # a boot image that really differs: a kernel update, as far as the TPM can tell
  lab_ssh_root bash -c "date > /etc/lab-$1; echo 'FILES+=(/etc/lab-$1)' >> /etc/mkinitcpio.conf.d/lab-rebuild.conf; limine-update >/dev/null 2>&1"
}

checkpoint installed build_installed; mkdir -p "$shots"
lab_ssh_root bash -c 'snapper -c root create -d before-setup && limine-snapper-sync' >/dev/null 2>&1
keys_before=$(pk)

echo "[setup]"
j=$(root_with "$LAB_PASSWORD" "monarchy-encryption setup --json 2>/dev/null") && key=$(jq -r .recovery_key <<<"$j") && [[ -n $key ]] \
  && ok "setup succeeds on a stock install" || bad "setup failed: $j"
[[ $(st '[.boot_menu.editor_locked, .boot_menu.config_protected, .boot_menu.fallback_protected, .tpm_policy.exists]') == '[true,true,true,false]' ]] \
  && ok "status: menu locked and protected, fallback protected, no TPM policy until the restart" || bad "status: $(st .)"
[[ $(pk) == "$keys_before" ]] && ok "the firmware's Secure Boot variables are untouched" || bad "Secure Boot variables changed"

echo "[the restart]"
untyped restart && ok "starts with nothing typed" || bad "the restart after setup asked for a key"
finished && [[ $(st '[.protected, .tpm_policy.pcrs, .tpm_policy.current]') == '[true,[4,11],true]' ]] \
  && ok "protected; the TPM policy over PCR 4 and 11 covers the boot files" || bad "status: $(st .)"
lab_ssh_root bash -c 'ls /boot/loader/credentials/pcrlock.*.cred' >/dev/null 2>&1 && ok "the policy's credential is on the ESP for the initramfs" || bad "no pcrlock credential"
untyped again && ok "and the next start too" || bad "the second start asked for a key"

echo "[the boot menu]"
lab_ssh_root systemctl reboot >/dev/null 2>&1 || true
for _ in $(seq 60); do sleep 0.5; menu_text | grep -qi "Booting automatically" && break; done
press "$LAB" down; sleep 0.3; press "$LAB" up; sleep 0.3
text=$(menu_text)
[[ $text == *"ENTER"* && $text != *"Edit"* && $text != *"Blank Entry"* ]] && ok "the menu offers no Edit and no Blank Entry" || bad "menu: $text"
press "$LAB" e; sleep 1; press "$LAB" b; sleep 1
[[ $(menu_text) != *"cmdline"* ]] && ok "pressing e and b opens no editor" || bad "an editor opened"
press "$LAB" ret; up_untyped 120 || { bad "the menu's default entry asked for a key"; unlock_and_wait "$LAB" 300 "$key"; }

echo "[a plain Limine, as someone with the laptop could put on the ESP]"
lab_ssh_root bash -c 'cp /boot/EFI/limine/limine_x64.efi /root/limine.keep; cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/limine_x64.efi'
lab_ssh_root systemctl reboot >/dev/null 2>&1 || true; for _ in $(seq 60); do lab_ssh true 2>/dev/null || break; sleep 1; done
prompted plain-limine && ok "the disk stays locked: it asks for the recovery key, which opens it" || bad "the TPM opened the disk for a plain Limine"
lab_ssh_root bash -c 'cp /root/limine.keep /boot/EFI/limine/limine_x64.efi; rm /root/limine.keep'
lab_ssh_root monarchy-encryption reassert >/dev/null 2>&1
untyped back && ok "Limine put back: nothing typed again (the policy rewritten from a start that missed it)" || bad "still asks after putting Limine back"

echo "[a new boot image, then a snapshot]"
rebuild update; lab_ssh_root bash -c 'snapper -c root create -d after-update && limine-snapper-sync' >/dev/null 2>&1
[[ $(st .tpm_policy.current) == true ]] && ok "the policy covers the new boot files" || bad "policy: $(st .tpm_policy)"
untyped update && ok "starts with nothing typed" || bad "asked for a key after an update"

echo "[snapshots from the boot menu]"
to_snapshot 1
if up_untyped 120 && [[ $(lab_ssh 'findmnt -no FSTYPE /') == overlay ]]; then ok "the newest snapshot (the current boot image) starts with nothing typed"
else screenshot "$LAB" "$shots/snapshot-new.png"; bad "the newest snapshot didn't start untyped ($shots/snapshot-new.png)"; unlock_and_wait "$LAB" 300 "$key"; fi
untyped after-new-snapshot || bad "the start after a snapshot asked for a key"
to_snapshot 2
if prompted snapshot-old && [[ $(lab_ssh 'findmnt -no FSTYPE /') == overlay ]]; then
  ok "the one from before setup (an older boot image) asks for the recovery key, and starts with it"
else bad "the snapshot from before setup: $(lab_ssh 'findmnt -no FSTYPE /' 2>&1) ($shots)"; fi
untyped after-old-snapshot && ok "the next normal start: nothing typed" || bad "asked for a key after the old snapshot"

echo "[a changed boot menu]"
lab_ssh_root sed -i 's/^editor_enabled: no$/editor_enabled: yes/' /boot/limine.conf
lab_ssh_root systemctl reboot >/dev/null 2>&1 || true
halted=""; for _ in $(seq 40); do sleep 1; t=$(menu_text); [[ $t == *"CHECKSUM MISMATCH"* ]] && { halted=1; break; }; done
[[ -n $halted ]] && ok "Limine refuses to start a changed menu" || { screenshot "$LAB" "$shots/tamper.png"; bad "no checksum panic (screen: $shots/tamper.png)"; }
qmp "$LAB" '"quit"' >/dev/null

((fail)) && { echo "RESULT: FAIL"; exit 1; }
echo "RESULT: ALL PASS (the lab VM is stopped; its menu was changed on purpose: test/vm/reset.sh)"
