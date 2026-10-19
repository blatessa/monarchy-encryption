#!/bin/bash
# Lab: recovery-key on a laptop after setup's first run. The key opens the real disk and starts the laptop when typed at the disk
# prompt; after it's replaced, the old one opens nothing; the key is written nowhere on the laptop. Resets the lab
# first. About 6 minutes.
source "$(dirname "$0")/lib.sh"
fail=0
ok()  { printf '  PASS %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
RE='^[a-z]{8}(-[a-z]{8}){7}$'
# Secrets go to the VM on stdin (root_with), never in a command line: sudo logs those to the journal, where `nowhere`
# looks.
# recovery_key SECRET: recovery-key --json with SECRET on stdin, as an MDM runs it; prints the JSON
recovery_key() { root_with "$1" "monarchy-encryption recovery-key --json 2>/dev/null" || true; }
field() { jq -r ".$1 // empty" <<<"$2" 2>/dev/null || true; }   # field NAME JSON, empty when it isn't JSON (lib.sh: set -e)
opens() { root_with "$1" "cryptsetup open --test-passphrase --disable-external-tokens --key-file=- /dev/vda2" >/dev/null 2>&1; }
# nowhere KEY: the key isn't in the journal or any file under /etc, /root, /home, /var/log, /tmp or the ESP
nowhere() {
  ! root_with "$1" "bash -c 'IFS= read -r k || true; journalctl -o cat | grep -qF -- \"\$k\" || grep -rqsF -- \"\$k\" /etc /root /home /var/log /tmp /boot'"
}

"$VM/reset.sh"; "$VM/run.sh" >/dev/null
"$VM/install-package.sh"
root_with "$LAB_PASSWORD" "monarchy-encryption setup" >/dev/null 2>&1 || bad "setup failed"
lab_reboot "$LAB"   # Secure Boot on, the menu editor locked: the recovery key's letters can't open it

nowhere "$LAB_USER:x:" && bad "the leak search finds nothing, even what is there" || ok "the leak search finds what is on the laptop (/etc/passwd)"

echo "[a new recovery key]"
j=$(recovery_key "$LAB_PASSWORD"); key1=$(field recovery_key "$j")
[[ $key1 =~ $RE && $(field previous_key "$j") == removed ]] && ok "replaces setup's, with the passphrase on stdin" || bad "recovery-key: $j"
opens "$key1" && ok "it opens the disk" || bad "key 1 doesn't open the disk"
opens "$LAB_PASSWORD" && ok "the passphrase still does" || bad "the passphrase no longer opens the disk"
nowhere "$key1" && ok "the key is written nowhere on the laptop (journal included)" || bad "key 1 found on the laptop"

echo "[typed at the disk prompt]"
lab_reboot "$LAB" "$key1" && ok "the laptop starts with the recovery key typed in place of the passphrase"
[[ $(lab_ssh_root systemctl is-active systemd-cryptsetup@root.service) == active ]] && ok "systemd opened the disk" || bad "systemd-cryptsetup@root not active"

echo "[replaced, unlocked with the current recovery key]"
j=$(recovery_key "$key1"); key2=$(field recovery_key "$j")
[[ $key2 =~ $RE && $key2 != "$key1" && $(field previous_key "$j") == removed ]] && ok "a new key; the previous one removed" || bad "rotate: $j"
opens "$key2" && ok "the new key opens the disk" || bad "key 2 doesn't open the disk"
opens "$key1" && bad "the old key still opens the disk" || ok "the old key no longer does"
opens "$LAB_PASSWORD" && ok "the passphrase still does" || bad "the passphrase no longer opens the disk"
[[ $(lab_ssh_root systemd-cryptenroll /dev/vda2 | grep -c recovery) == 1 ]] && ok "one recovery slot on the disk" || bad "slots: $(lab_ssh_root systemd-cryptenroll /dev/vda2)"
nowhere "$key2" && ok "the new key is written nowhere either" || bad "key 2 found on the laptop"
lab_reboot "$LAB" "$key2" && ok "the laptop starts with the new key"

echo "[a wrong passphrase]"
before=$(lab_ssh_root systemd-cryptenroll /dev/vda2)
out=$(root_with wrong "monarchy-encryption recovery-key --json" 2>&1) && bad "accepted: $out" || ok "refused"
[[ $(lab_ssh_root systemd-cryptenroll /dev/vda2) == "$before" ]] && opens "$key2" && ok "nothing changed; the key still works" || bad "slots changed"

((fail)) && { echo "RESULT: FAIL"; exit 1; }; echo "RESULT: ALL PASS"
