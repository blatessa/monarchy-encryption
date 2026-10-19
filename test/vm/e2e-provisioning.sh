#!/bin/bash
# Lab: Omarchy's provisioning staged as a factory reset or deferred install leaves it (a throwaway keyslot, its key
# file in the boot image, cryptkey=). setup refuses and changes nothing, so the laptop keeps unlocking itself with that
# key file; once provisioning is done, setup goes ahead. Resets the lab first. About 6 minutes.
source "$(dirname "$0")/lib.sh"
fail=0
ok()  { printf '  PASS %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
# what setup would change: the initramfs settings, crypttab, the boot image and Limine, the keyslots, sbctl's keys
fingerprint() {
  lab_ssh_root bash -c 'md5sum /etc/crypttab /etc/mkinitcpio.conf.d/* /boot/EFI/Linux/*.efi /boot/EFI/limine/limine_x64.efi 2>/dev/null
    cryptsetup luksDump /dev/vda2 | grep -E "^ +[0-9]+: luks2"; ls /var/lib/sbctl/keys 2>/dev/null; true'
}

"$VM/reset.sh"; "$VM/run.sh" >/dev/null
"$VM/install-package.sh"

echo "[provisioning staged, as a factory reset leaves it]"
lab_ssh_root bash -c 'k=$(head -c 24 /dev/urandom | base64 | tr -dc a-zA-Z0-9); printf "%s" "$k" > /tmp/k
  printf "monarchy" | cryptsetup luksAddKey --key-file=- /dev/vda2 /tmp/k
  install -d -m 755 /var/lib/omarchy/provisioning; install -m600 /tmp/k /var/lib/omarchy/provisioning/luks-key
  touch /var/lib/omarchy/provisioning/pending; install -Dm600 /tmp/k /etc/omarchy/provisioning.key; rm /tmp/k
  echo "KERNEL_CMDLINE[default]+=\" cryptkey=rootfs:/etc/omarchy/provisioning.key\"" > /etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf
  echo "FILES+=(/etc/omarchy/provisioning.key)" > /etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf
  limine-update >/dev/null 2>&1'
restart_untyped && ok "the laptop unlocks itself with provisioning's key file" || { bad "provisioning's unlock doesn't work here"; unlock_and_wait "$LAB" 300; }
before=$(fingerprint)
out=$(root_with "$LAB_PASSWORD" "monarchy-encryption setup" 2>&1) && bad "setup went ahead: $out" || ok "setup refuses"
[[ $out == *"first-boot setup hasn't finished"* ]] && ok "and says to finish first-boot setup" || bad "message: $out"
[[ $(fingerprint) == "$before" ]] && ok "nothing changed" || bad "changed: $(diff <(echo "$before") <(fingerprint))"
[[ $(lab_ssh monarchy-encryption status --json | jq -c '[.disk.provisioning_pending, .protected]') == '[true,false]' ]] \
  && ok "status: provisioning pending, not protected" || bad "status: $(lab_ssh monarchy-encryption status --json)"
restart_untyped && ok "and it still unlocks itself" || { bad "it now asks for a passphrase"; unlock_and_wait "$LAB" 300; }

echo "[provisioning done]"
lab_ssh_root bash -c 'rm -rf /var/lib/omarchy/provisioning /etc/omarchy/provisioning.key /etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf /etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf; limine-update >/dev/null 2>&1'
[[ $(root_with "$LAB_PASSWORD" "monarchy-encryption setup --json 2>/dev/null" | jq -r .done) == false ]] && ok "setup goes ahead" || bad "setup after provisioning"
lab_reboot "$LAB" && ok "and the laptop starts (passphrase typed)"

((fail)) && { echo "RESULT: FAIL"; exit 1; }; echo "RESULT: ALL PASS"
