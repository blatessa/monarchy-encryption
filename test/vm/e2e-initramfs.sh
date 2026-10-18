#!/bin/bash
# Lab: setup's systemd initramfs on a clean install, then what only a real boot can show: the themed prompt, systemd
# opening the disk, a snapshot entry, hibernation, and re-running setup. Resets the lab first. About 5 minutes.
source "$(dirname "$0")/lib.sh"
fail=0
ok()  { printf '  PASS %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
shots=$LAB/e2e-initramfs
screen_text() { screenshot "$LAB" "$shots/s.png"; tesseract "$shots/s.png" - 2>/dev/null; }
corner() { magick "$shots/s.png" -format '%[hex:p{20,20}]' info: 2>/dev/null; }   # the background colour
st() { lab_ssh_root monarchy-encryption status --json | jq -r "$1"; }
fingerprint() { lab_ssh_root bash -c 'md5sum /etc/mkinitcpio.conf.d/* /etc/crypttab /boot/EFI/Linux/*.efi /boot/limine.conf /etc/default/limine'; }

"$VM/reset.sh"; "$VM/run.sh" >/dev/null; mkdir -p "$shots"
"$VM/install-package.sh"

echo "[setup]"
out=$(lab_ssh_root monarchy-encryption setup 2>&1) && ok "setup succeeds" || { bad "setup failed"; sed 's/^/      /' <<<"$out"; }
[[ $(st '[.disk.encrypted, .disk.systemd_initramfs] | map(tostring) | join(" ")') == "true true" ]] && ok "status: systemd initramfs" || bad "status: $(st .disk)"

echo "[the first start]"
lab_ssh_root systemctl reboot >/dev/null 2>&1 || true
themed=""
for _ in $(seq 60); do
  sleep 1; t=$(screen_text)
  [[ $t == *Bootloader* || $t == *"Booting automatically"* ]] && continue      # still Limine's menu
  if [[ $t == *assphrase* || $t == *"password is required"* ]]; then break; fi   # a plain-text prompt
  [[ $(corner) != 000000* ]] && { themed=1; break; }                               # Plymouth's dark blue, no text
done
cp "$shots/s.png" "$shots/prompt.png"
[[ -n $themed ]] && ok "Omarchy's themed passphrase screen" || bad "not the themed prompt (screen: $shots/prompt.png)"
unlock_and_wait "$LAB" 300
[[ $(lab_ssh 'systemctl is-active systemd-cryptsetup@root.service') == active ]] && ok "systemd opened the disk" || bad "systemd-cryptsetup@root not active"
[[ $(lab_ssh 'findmnt -no SOURCE /') == "/dev/mapper/root[/@]" ]] && ok "/ is on /dev/mapper/root as before" || bad "root: $(lab_ssh 'findmnt -no SOURCE /')"

echo "[setup again]"
before=$(fingerprint)
out=$(lab_ssh_root monarchy-encryption setup 2>&1) || bad "setup rerun failed: $out"
[[ $(fingerprint) == "$before" ]] && ok "re-running changes nothing, the boot image included" || bad "rerun changed: $(diff <(echo "$before") <(fingerprint))"

echo "[a snapshot]"
lab_ssh_root bash -c 'snapper -c root create -d e2e-initramfs && limine-snapper-sync' >/dev/null 2>&1
lab_ssh_root systemctl reboot >/dev/null 2>&1 || true
for _ in $(seq 60); do sleep 0.5; screen_text | grep -qi "Booting automatically" && break; done
press "$LAB" down; sleep 0.4; press "$LAB" ret; sleep 0.4; press "$LAB" down; sleep 0.4; press "$LAB" ret; sleep 0.4
press "$LAB" down; sleep 0.4; press "$LAB" ret; sleep 3
if (unlock_and_wait "$LAB" 300) 2>/dev/null && [[ $(lab_ssh 'findmnt -no FSTYPE /') == overlay ]] && lab_ssh 'touch /tmp/w'; then
  ok "it starts from the boot menu, writable"
else screenshot "$LAB" "$shots/snapshot.png"; bad "snapshot didn't start (screen: $shots/snapshot.png)"
  qmp "$LAB" '"system_reset"' >/dev/null; sleep 3; unlock_and_wait "$LAB" 300; fi
lab_reboot "$LAB"

echo "[hibernation]"
# Resume is unreliable in the lab even on a stock install (#21, docs/dev/findings.md), so this is reported, not
# counted: up to three tries, stopping at the first real resume. Make it a check again once #21 is fixed.
resumed=""
for try in 1 2 3; do
  ((try == 1)) || lab_reboot "$LAB"
  id=$(lab_ssh 'cat /proc/sys/kernel/random/boot_id | tee /tmp/marker')
  lab_ssh_root systemctl hibernate >/dev/null 2>&1 || true
  for _ in $(seq 120); do vm_running "$LAB" || break; sleep 1; done
  vm_running "$LAB" && { qmp "$LAB" '"quit"' >/dev/null; sleep 2; }
  start_vm "$LAB"; unlock_and_wait "$LAB" 300
  [[ $(lab_ssh 'cat /tmp/marker 2>/dev/null') == "$id" ]] && { resumed=$try; break; }
done
if [[ -n $resumed ]]; then ok "it resumes after the passphrase, with what was in memory (try $resumed of 3)"
else printf '  NOTE %s\n' "no resume in 3 tries: the lab's hibernation is unreliable even on stock (#21), so this is not counted"; fi

"$VM/stop.sh"
((fail)) && { echo "RESULT: FAIL"; exit 1; }
echo "RESULT: ALL PASS"
