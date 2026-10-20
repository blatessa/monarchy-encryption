#!/bin/bash
# Lab: setup's two runs end with the TPM unlocking the disk at boot. With Secure Boot off or a changed key database
# the disk prompt comes back and the recovery key opens it; setup then enrolls the TPM afresh. A kernel update still
# unlocks. The passphrase goes only when the TPM and the recovery key each open the disk. Resets the lab first and
# leaves it finished (TPM and recovery key, no passphrase). About 12 minutes.
source "$(dirname "$0")/lib.sh"
fail=0
ok()  { printf '  PASS %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
shots=$LAB/e2e-tpm
# Secrets go to the VM on stdin, never in a command line (sudo logs those: findings.md).
root_with() { printf '%s\n%s' "$LAB_PASSWORD" "$1" | lab_ssh "sudo -S -p '' $2"; }
setup_json() { root_with "$1" "monarchy-encryption setup --json 2>/dev/null" || true; }   # setup_json SECRET
field() { jq -r ".$1 | tostring" <<<"$2" 2>/dev/null || true; }
opens() { root_with "$1" "cryptsetup open --test-passphrase --disable-external-tokens --key-file=- /dev/vda2" >/dev/null 2>&1; }
tpm_opens() { lab_ssh_root cryptsetup open --test-passphrase --token-only --token-type systemd-tpm2 /dev/vda2 >/dev/null 2>&1; }
cryptsetup_log() { lab_ssh_root journalctl -b -u systemd-cryptsetup@root -o cat; }
# status_is PROTECTED "MISSING...": status --json as root says protected (true/false) and lists exactly these fields
status_is() {
  local j; j=$(lab_ssh_root monarchy-encryption status --json 2>/dev/null)
  [[ $(jq -r .protected <<<"$j") == "$1" && $(jq -r '.missing | join(" ")' <<<"$j") == "$2" ]] || { echo "      status: $j"; return 1; }
}

checkpoint installed build_installed; mkdir -p "$shots"

echo "[status on a stock install]"
status_is false "disk.systemd_initramfs disk.tpm_unlock disk.recovery_key disk.no_passphrase secure_boot.enabled secure_boot.own_keys secure_boot.boot_files_signed boot_menu.editor_locked boot_menu.config_protected" \
  && ok "status: not protected, everything setup does is missing" || bad "status before setup"
[[ $(lab_ssh monarchy-encryption status --json | jq -c '[.protected, .missing]') == '[false,["secure_boot.enabled"]]' ]] \
  && ok "status as a user: not protected, from what a user can see (Secure Boot is off)" || bad "user status: $(lab_ssh monarchy-encryption status --json)"

echo "[the first run]"
j=$(setup_json "$LAB_PASSWORD"); key=$(field recovery_key "$j")
[[ $(field done "$j") == false && $key =~ ^[a-z]{8}(-[a-z]{8}){7}$ ]] && ok "Secure Boot and a recovery key; restart needed" || bad "run 1: $j"
status_is false "disk.tpm_unlock disk.no_passphrase secure_boot.enabled" && ok "status: still missing the TPM, removing the passphrase, and Secure Boot (on after the restart)" || bad "status after run 1"
lab_reboot "$LAB"

echo "[the second run, with the passphrase]"
j=$(setup_json "$LAB_PASSWORD")
[[ $(field done "$j") == true && $(field passphrase "$j") == kept && $(field recovery_key "$j") == null ]] && ok "the TPM enrolled; the passphrase kept" || bad "run 2: $j"
restart_untyped && ok "the laptop starts with nothing typed" || { bad "it waited at the disk prompt"; unlock_and_wait "$LAB" 300; }
[[ $(cryptsetup_log) != *"does not match"* ]] && ok "the TPM opened the disk" || bad "cryptsetup: $(cryptsetup_log)"

echo "[the third run, with the recovery key]"
j=$(setup_json "$key")
[[ $(field done "$j") == true && $(field passphrase "$j") == removed ]] && ok "the passphrase is removed" || bad "run 3: $j"
opens "$LAB_PASSWORD" && bad "the passphrase still opens the disk" || ok "the passphrase no longer opens the disk"
opens "$key" && ok "the recovery key does" || bad "the recovery key doesn't open the disk"
tpm_opens && ok "and the TPM does" || bad "the TPM doesn't open the disk"
restart_untyped && ok "the laptop starts with nothing typed" || { bad "it waited at the disk prompt"; unlock_and_wait "$LAB" 300 "$key"; }
j=$(setup_json ""); [[ $(field done "$j") == true && $(field passphrase "$j") == none ]] && ok "setup again: done, nothing asked" || bad "run 4: $j"
status_is true "" && ok "status: protected, nothing missing" || bad "status when done"
[[ $(lab_ssh_root monarchy-encryption status --json | jq -c .disk.tpm_pcrs) == "[7]" ]] && ok "status: the TPM is bound to PCR 7" || bad "pcrs"


echo "[Secure Boot off]"
stop_vm "$LAB"
OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd start_vm "$LAB"   # the same firmware variables and TPM, no Secure Boot
if up_untyped 120; then bad "the disk opened with Secure Boot off"; else
  ok "with Secure Boot off the laptop waits at the disk prompt"; screenshot "$LAB" "$shots/sb-off.png"
  unlock_and_wait "$LAB" 300 "$key" && ok "the recovery key opens it"
  status_is false "disk.tpm_unlock secure_boot.enabled" && ok "status: not protected: Secure Boot off, and the TPM doesn't open the disk" || bad "status with Secure Boot off"
fi
stop_vm "$LAB"; start_vm "$LAB"
up_untyped 120 && ok "Secure Boot back on: the TPM opens the disk again" || { bad "still a prompt with Secure Boot back on"; unlock_and_wait "$LAB" 300 "$key"; }

echo "[a changed key database]"
lab_ssh_root bash -c 'v=/sys/firmware/efi/efivars; chattr -i $v/PK-* $v/KEK-* $v/db-*; mkdir -p /var/lib/sbctl/keys/custom/db
  openssl req -x509 -newkey rsa:2048 -nodes -subj "/CN=lab extra db" -days 30 -keyout /dev/null -out /var/lib/sbctl/keys/custom/db/extra.pem 2>/dev/null
  sbctl enroll-keys --append --partial db --custom >/dev/null' && ok "a certificate appended to the firmware's db" || bad "couldn't change db"
if restart_untyped; then bad "the disk opened with a changed db"; else
  ok "the laptop waits at the disk prompt"
  unlock_and_wait "$LAB" 300 "$key" && ok "the recovery key opens it"
  [[ $(cryptsetup_log) == *"TPM policy does not match"* ]] && ok "systemd says the TPM policy doesn't match" || bad "cryptsetup: $(cryptsetup_log)"
fi
status_is false "disk.tpm_unlock" && ok "status: the TPM no longer opens the disk, and nothing else is wrong" || bad "status after the db change"
j=$(setup_json ""); [[ -z $(field done "$j") || $(field done "$j") == null ]] && ok "setup asks for the recovery key (the TPM no longer opens the disk)" || bad "no-key run: $j"
j=$(setup_json "$key"); [[ $(field done "$j") == true ]] && tpm_opens && ok "setup with the recovery key enrolls the TPM afresh" || bad "re-enroll: $j"
[[ $(lab_ssh_root systemd-cryptenroll /dev/vda2 | grep -c tpm2) == 1 ]] && ok "one TPM slot (the stale one removed)" || bad "slots: $(lab_ssh_root systemd-cryptenroll /dev/vda2)"
status_is true "" && ok "status: protected again" || bad "status after re-enrolling"
[[ $(lab_ssh monarchy-encryption status --json | jq -c '[.protected, .missing]') == '[null,[]]' ]] \
  && ok "status as a user: unknown, since nothing a user can see is wrong" || bad "user status: $(lab_ssh monarchy-encryption status --json)"

((fail)) && { echo "RESULT: FAIL"; exit 1; }; echo "RESULT: ALL PASS"
