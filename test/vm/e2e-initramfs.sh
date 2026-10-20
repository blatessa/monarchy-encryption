#!/bin/bash
# Lab: setup's systemd initramfs on a clean install, then what only a real boot can show: systemd opening the disk, the
# themed prompt, re-running setup, and a snapshot entry. Starts from the installed checkpoint. About 3 minutes.
# Hibernation isn't here: the lab's is unreliable even on stock (#21); hibernate-loop.sh tries it on demand.
source "$(dirname "$0")/lib.sh"
fail=0
ok()  { printf '  PASS %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
shots=$LAB/e2e-initramfs
screen_text() { screenshot "$LAB" "$shots/s.png"; tesseract "$shots/s.png" - 2>/dev/null; }
corner() { magick "$shots/s.png" -format '%[hex:p{20,20}]' info: 2>/dev/null; }   # the background colour
st() { lab_ssh_root monarchy-encryption status --json | jq -r "$1"; }
fingerprint() { lab_ssh_root bash -c 'md5sum /etc/mkinitcpio.conf.d/* /etc/crypttab /boot/EFI/Linux/*.efi /boot/limine.conf /etc/default/limine'; }

checkpoint installed build_installed; mkdir -p "$shots"

echo "[setup]"
key=$(root_with "$LAB_PASSWORD" "monarchy-encryption setup 2>/dev/null") && [[ -n $key ]] && ok "setup succeeds" || bad "setup failed"
[[ $(st '[.disk.encrypted, .disk.systemd_initramfs] | map(tostring) | join(" ")') == "true true" ]] && ok "status: systemd initramfs" || bad "status: $(st .disk)"

echo "[the restart: the systemd initramfs, nothing typed]"
restart_untyped && finished && ok "it starts with nothing typed and finishes setup" || { bad "the restart after setup"; unlock_and_wait "$LAB" 300 "$key"; }
[[ $(lab_ssh 'systemctl is-active systemd-cryptsetup@root.service') == active ]] && ok "systemd opened the disk" || bad "systemd-cryptsetup@root not active"
[[ $(lab_ssh 'findmnt -no SOURCE /') == "/dev/mapper/root[/@]" ]] && ok "/ is on /dev/mapper/root as before" || bad "root: $(lab_ssh 'findmnt -no SOURCE /')"

echo "[the disk prompt (a cleared TPM)]"
stop_vm "$LAB"; mv "$LAB/tpm" "$LAB/tpm.own"; cp -r --reflink=auto "$BASE/tpm" "$LAB/tpm"; start_vm "$LAB"
themed=""
for _ in $(seq 60); do
  sleep 1; t=$(screen_text)
  [[ $t == *Bootloader* || $t == *"Booting automatically"* ]] && continue      # still Limine's menu
  if [[ $t == *assphrase* || $t == *"password is required"* ]]; then break; fi   # a plain-text prompt
  [[ $(corner) != 000000* ]] && { themed=1; break; }                               # Plymouth's dark blue, no text
done
cp "$shots/s.png" "$shots/prompt.png"
[[ -n $themed ]] && ok "Omarchy's themed disk prompt" || bad "not the themed prompt (screen: $shots/prompt.png)"
unlock_and_wait "$LAB" 300 "$key" && ok "the recovery key typed there opens the disk"
stop_vm "$LAB"; rm -rf "$LAB/tpm"; mv "$LAB/tpm.own" "$LAB/tpm"; start_vm "$LAB"
up_untyped 120 || { bad "its own TPM back: asked for a key"; unlock_and_wait "$LAB" 300 "$key"; }

echo "[setup again]"
before=$(fingerprint)
out=$(root_with "" "monarchy-encryption setup" 2>&1) || bad "setup rerun failed: $out"
[[ $(fingerprint) == "$before" ]] && ok "re-running changes nothing, the boot image included" || bad "rerun changed: $(diff <(echo "$before") <(fingerprint))"

echo "[a snapshot]"
lab_ssh_root bash -c 'snapper -c root create -d e2e-initramfs && limine-snapper-sync' >/dev/null 2>&1
lab_ssh_root systemctl reboot >/dev/null 2>&1 || true
for _ in $(seq 60); do sleep 0.5; screen_text | grep -qi "Booting automatically" && break; done
press "$LAB" down; sleep 0.4; press "$LAB" ret; sleep 0.4; press "$LAB" down; sleep 0.4; press "$LAB" ret; sleep 0.4
press "$LAB" down; sleep 0.4; press "$LAB" ret; sleep 3
if up_untyped 120 && [[ $(lab_ssh 'findmnt -no FSTYPE /') == overlay ]] && lab_ssh 'touch /tmp/w'; then
  ok "it starts from the boot menu with nothing typed, writable"
else screenshot "$LAB" "$shots/snapshot.png"; bad "snapshot didn't start (screen: $shots/snapshot.png)"
  qmp "$LAB" '"system_reset"' >/dev/null; sleep 3; unlock_and_wait "$LAB" 300 "$key"; fi
"$VM/stop.sh"
((fail)) && { echo "RESULT: FAIL"; exit 1; }
echo "RESULT: ALL PASS"
