#!/bin/bash
# Lab: release on a laptop that's fully set up, then Omarchy's own factory reset and first-boot setup, then setup again.
# release gives the disk a passphrase back and removes the TPM and its policy; the reset (asked for that passphrase)
# and first-boot setup run as Omarchy ships them, driven by keystrokes; setup then
# takes the laptop back to protected. Starts from the set-up checkpoint (lib.sh). LAB_SAVE=1 saves a checkpoint after
# first-boot setup, for debugging what follows. About 15 minutes.
source "$(dirname "$0")/lib.sh"
fail=0
ok()  { printf '  PASS %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
NEWPASS=released-disk-42   # no e or b: early keystrokes can land in Limine's menu
shots=$LAB/e2e-release
# the console's text without spaces: OCR splits monospaced words ("Conf irm>")
screen_text() { screenshot "$LAB" "$shots/s.png"; tesseract "$shots/s.png" - 2>/dev/null | tr -d ' \t'; }
# wait_screen TEXT SECONDS [KEY]: until the console shows TEXT (case and spaces ignored), pressing KEY every 10 s if given
wait_screen() {
  local start=$SECONDS next=10
  until screen_text | grep -qi -- "${1// /}"; do
    ((SECONDS - start < $2)) || { cp "$shots/s.png" "$shots/timeout-${1// /_}.png"; return 1; }
    if [[ -n ${3:-} ]] && ((SECONDS - start >= next)); then press "$LAB" "$3"; ((next += 10)); fi
    sleep 2
  done
}
answer() { type_text "$LAB" "$1"; press "$LAB" ret; sleep 2; }   # answer TEXT: type it and press Return
st() { lab_ssh_root monarchy-encryption status --json | jq -c "$1"; }

checkpoint set-up build_set_up; key=$RECOVERY_KEY; mkdir -p "$shots"
[[ $(st '[.protected, .missing]') == '[true,[]]' ]] && ok "set up: protected" || bad "not set up: $(st .)"

echo "[release]"
out=$(root_with "$NEWPASS" "monarchy-encryption release" 2>&1) && ok "release succeeds" || bad "release: $out"
[[ $(st '[.disk.tpm_enrolled, .disk.passphrase, .tpm_policy.exists]') == '[false,true,false]' ]] \
  && ok "status: no TPM, a passphrase, no TPM policy" || bad "status: $(st .)"
lab_ssh_root bash -c 'ls /etc/boot/hooks/post.d/*monarchy* /etc/systemd/system/*/monarchy-encryption-* /var/lib/monarchy-encryption 2>/dev/null' \
  && bad "left behind: $(lab_ssh_root bash -c 'ls -d /etc/boot/hooks/post.d/*monarchy* /etc/systemd/system/*/monarchy-encryption-* /var/lib/monarchy-encryption 2>/dev/null')" \
  || ok "nothing of ours runs at start or on updates"
lab_reboot "$LAB" "$NEWPASS" && ok "the laptop starts with the new passphrase typed"

echo "[Omarchy's factory reset]"
# Harness only: the reset removes every account, so leave our ssh key where first-boot provisioning installs it from
# (@factory is a read-only snapshot: writable for this one copy).
lab_ssh_root bash -c 'mkdir -p /mnt/top && mount -o subvolid=5 /dev/mapper/root /mnt/top && f=/mnt/top/@factory &&
  btrfs property set -ts $f ro false && install -Dm644 /home/lab/.ssh/authorized_keys $f/var/lib/omarchy/provisioning/authorized_keys &&
  btrfs property set -ts $f ro true; umount /mnt/top' && ok "our ssh key left for first-boot provisioning" || bad "couldn't stage the ssh key"
# its questions: type "reset", the current disk passphrase, then "Reboot now?" (Return), each answered once it shows
# in the session's output. gum needs a terminal size (it panics on a 0-column pty).
# seen TEXT SECONDS: TEXT has shown in the session (its output has colour and cursor codes between the characters)
seen() {
  local s=$SECONDS
  until sed -E 's/\x1b\[[0-9;?>=]*[a-zA-Z]//g' "$shots/reset.log" 2>/dev/null | tr -d '\r' | grep -aq -- "$1"; do
    ((SECONDS - s < $2)) || return 1; sleep 1
  done
}
: > "$shots/reset.log"
{ printf '%s\n' "$LAB_PASSWORD"; seen "Type 'reset'" 60 && printf 'reset\r'; seen "Passphrase>" 60 && printf '%s\r' "$NEWPASS"
  seen "Reboot" 900 && sleep 1 && printf '\r'; sleep 20; } |
  lab_ssh "sudo -S -p '' script -qec 'stty cols 120 rows 40; omarchy-system-factory-reset' /dev/null" >"$shots/reset.log" 2>&1 || true
grep -q "Reset staged" "$shots/reset.log" && ok "the reset is staged (it accepted the new passphrase)" || bad "reset: $(tail -5 "$shots/reset.log")"

echo "[first-boot setup, after the restart]"
for _ in $(seq 60); do lab_ssh true 2>/dev/null || break; sleep 2; done
wait_screen "keyboard" 600 ret && ok "it starts with nothing typed (the reset's key file) into first-boot setup" || bad "no first-boot setup on screen ($shots)"
press "$LAB" ret   # keyboard: English (US)
wait_screen "Username" 60 && answer "$LAB_USER" || bad "no username prompt"
wait_screen "Password" 60 && answer "$LAB_PASSWORD" || bad "no password prompt"
wait_screen "Confirm" 60 && answer "$LAB_PASSWORD" || bad "no password confirmation"
wait_screen "Full name" 60 && press "$LAB" ret && sleep 2 || bad "no full name prompt"
wait_screen "Email" 60 && press "$LAB" ret && sleep 2 || bad "no email prompt"
wait_screen "Hostname" 60 && answer "$LAB_HOSTNAME" || bad "no hostname prompt"
wait_screen "Timezone" 60 && press "$LAB" ret && sleep 2 || bad "no timezone prompt"
wait_screen "look right" 60 && press "$LAB" ret || bad "no confirmation"
up_untyped 600 && ok "the new owner can sign in" || bad "no ssh after first-boot setup ($shots)"
# sshd answers before first-boot setup has finished re-keying the disk on tty1
for _ in $(seq 60); do lab_ssh_root test -e /var/lib/omarchy/provisioning/pending 2>/dev/null || break; sleep 5; done
lab_ssh_root test -e /var/lib/omarchy/provisioning/pending 2>/dev/null && bad "first-boot setup still pending after 5 minutes" || ok "first-boot setup finished"
[[ -n ${LAB_SAVE:-} ]] && checkpoint_save after-first-boot "$LAB_PASSWORD"   # debugging: test/vm/checkpoint.sh restore after-first-boot
[[ $(lab_ssh_root systemd-cryptenroll /dev/vda2 | grep -c '^ *[0-9]') == 1 ]] && ok "Omarchy re-keyed the disk to the owner's password (one slot)" || bad "slots: $(lab_ssh_root systemd-cryptenroll /dev/vda2)"

echo "[setup again]"
"$VM/install-package.sh"
key2=$(root_with "$LAB_PASSWORD" "monarchy-encryption setup --json 2>/dev/null" | jq -r .recovery_key)
[[ $key2 =~ ^[a-z]{8}(-[a-z]{8}){7}$ ]] && ok "setup's first run: a new recovery key" || bad "setup after the reset"
restart_untyped && finished && ok "the restart: nothing typed, setup finished" || { bad "the restart after setup"; unlock_and_wait "$LAB" 300; }
[[ $(st '[.protected, .missing]') == '[true,[]]' ]] && ok "protected again" || bad "status: $(st .)"
restart_untyped && ok "starts with nothing typed" || { bad "prompt after setting up again"; unlock_and_wait "$LAB" 300 "$key2"; }

((fail)) && { echo "RESULT: FAIL"; exit 1; }; echo "RESULT: ALL PASS"
