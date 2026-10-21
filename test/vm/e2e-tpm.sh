#!/bin/bash
# Lab: setup, then a restart with nothing typed: the one-time unlock opens the disk, and the boot service makes the TPM
# policy, ties the disk to it and removes the passphrase. A cleared TPM brings the disk prompt back and the recovery key
# opens it; setup then enrolls the TPM afresh. Starts from the installed checkpoint and leaves it finished (TPM and
# recovery key, no passphrase). About 8 minutes.
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
boot_log() { lab_ssh_root journalctl -b -u monarchy-encryption-boot -o cat; }

echo "[status on a stock install]"
status_is false "disk.systemd_initramfs disk.tpm_unlock disk.recovery_key disk.no_passphrase boot_menu.editor_locked boot_menu.config_protected tpm_policy.current" \
  && ok "status: not protected, everything setup does is missing" || bad "status before setup"
[[ $(lab_ssh monarchy-encryption status --json | jq -c '[.protected, .missing]') == '[null,[]]' ]] \
  && ok "status as a user: unknown, nothing a user can see is wrong" || bad "user status: $(lab_ssh monarchy-encryption status --json)"

echo "[setup]"
j=$(setup_json "$LAB_PASSWORD"); key=$(field recovery_key "$j")
[[ $(field done "$j") == false && $key =~ ^[a-z]{8}(-[a-z]{8}){7}$ ]] && ok "a recovery key; restart needed" || bad "setup: $j"
status_is false "disk.tpm_unlock disk.no_one_time_unlock disk.no_passphrase tpm_policy.current" \
  && ok "status: the TPM not bound yet, the one-time unlock and the passphrase there, no policy until the restart" || bad "status after setup"
[[ $(lab_ssh_root cryptsetup luksDump --dump-json-metadata /dev/vda2 | jq -c '[.tokens[] | select(.type == "systemd-tpm2") | [.["tpm2-pcrs"], (.tpm2_pcrlock // false)]]') == '[[[],false]]' ]] \
  && ok "the one-time unlock is bound to nothing" || bad "one-time: $(lab_ssh_root cryptsetup luksDump --dump-json-metadata /dev/vda2 | jq -c .tokens)"
tpm_opens && ok "the TPM opens the disk now" || bad "the one-time unlock doesn't open the disk"

echo "[the restart, with nothing typed]"
restart_untyped && ok "the laptop starts with nothing typed" || { bad "it waited at the disk prompt"; unlock_and_wait "$LAB" 300; }
finished && [[ $(boot_log) == *"setup finished"* ]] && ok "the boot service finished setup" || bad "boot: $(boot_log)"
lab_ssh_root journalctl -o cat | grep -qF "$key" && bad "a recovery key in the journal" || ok "no recovery key in the journal"
root_with "$key" "bash -c 'IFS= read -r k || true; grep -rqsF -- \"\$k\" /etc /root /var/lib /boot'" && bad "the recovery key is on the laptop's disk" || ok "nor on the disk (the policy's PIN isn't it)"
status_is true "" && ok "status: protected, nothing missing" || bad "status after the restart"
opens "$LAB_PASSWORD" && bad "the passphrase still opens the disk" || ok "the passphrase no longer opens the disk"
opens "$key" && ok "the recovery key does" || bad "the recovery key doesn't open the disk"
tpm_opens && ok "and the TPM does" || bad "the TPM doesn't open the disk"
[[ $(lab_ssh_root cryptsetup luksDump --dump-json-metadata /dev/vda2 | jq -c '[.tokens[] | select(.type == "systemd-tpm2") | [.["tpm2-pcrs"], .tpm2_pcrlock]]') == '[[[],true]]' ]] \
  && ok "one TPM slot, bound to the policy (the one-time unlock removed)" || bad "tokens: $(lab_ssh_root cryptsetup luksDump --dump-json-metadata /dev/vda2 | jq -c .tokens)"
restart_untyped && ok "the next start: nothing typed, through the policy" || { bad "it waited at the disk prompt"; unlock_and_wait "$LAB" 300 "$key"; }
[[ $(cryptsetup_log) != *"does not match"* && $(boot_log) != *"setup finished"* ]] && ok "the TPM opened the disk; the boot service only kept the policy" || bad "cryptsetup: $(cryptsetup_log) boot: $(boot_log)"
j=$(setup_json ""); [[ $(field done "$j") == true && $(field passphrase "$j") == none ]] && ok "setup again: done, nothing asked" || bad "run 4: $j"
status_is true "" && ok "status: protected, nothing missing" || bad "status when done"

echo "[a cleared TPM]"
stop_vm "$LAB"; rm -rf "$LAB/tpm"; cp -r --reflink=auto "$BASE/tpm" "$LAB/tpm"; start_vm "$LAB"
if up_untyped 90; then bad "the disk opened with a cleared TPM"; else
  ok "the laptop waits at the disk prompt"; screenshot "$LAB" "$shots/cleared.png"
  unlock_and_wait "$LAB" 300 "$key" && ok "the recovery key opens it"
fi
status_is false "disk.tpm_unlock" && ok "status: the TPM no longer opens the disk, and nothing else is wrong" || bad "status with a cleared TPM"
j=$(setup_json ""); [[ -z $(field done "$j") || $(field done "$j") == null ]] && ok "setup asks for the recovery key (the TPM no longer opens the disk)" || bad "no-key run: $j"
j=$(setup_json "$key"); [[ $(field done "$j") == true ]] && tpm_opens && ok "setup with the recovery key enrolls the TPM afresh" || bad "re-enroll: $j"
[[ $(lab_ssh_root systemd-cryptenroll /dev/vda2 | grep -c tpm2) == 1 ]] && ok "one TPM slot (the stale one removed)" || bad "slots: $(lab_ssh_root systemd-cryptenroll /dev/vda2)"
status_is true "" && ok "status: protected again" || bad "status after re-enrolling"
[[ $(lab_ssh monarchy-encryption status --json | jq -c '[.protected, .missing]') == '[null,[]]' ]] \
  && ok "status as a user: unknown, since nothing a user can see is wrong" || bad "user status: $(lab_ssh monarchy-encryption status --json)"

((fail)) && { echo "RESULT: FAIL"; exit 1; }; echo "RESULT: ALL PASS"
