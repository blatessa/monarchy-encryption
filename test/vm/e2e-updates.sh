#!/bin/bash
# Lab: updates on a laptop that's fully set up (TPM unlock, no passphrase). A kernel update, a limine upgrade (Omarchy's
# hook copies an unsigned Limine over ours), omarchy-refresh-limine (Omarchy's menu, editor on, over ours) and a
# simulated migration each leave it starting with nothing typed, everything signed and the menu locked. Starts from
# the set-up checkpoint (lib.sh). About 6 minutes, 10 when the checkpoint is rebuilt.
source "$(dirname "$0")/lib.sh"
fail=0
ok()  { printf '  PASS %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
shots=$LAB/e2e-updates; menu_text() { screenshot "$LAB" "$shots/m.png"; tesseract "$shots/m.png" - 2>/dev/null; }
pkg() { lab_ssh_root env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --noconfirm "$@" 2>&1; }
unsigned() { lab_ssh_root sbctl verify 2>&1 | grep '✗' | grep -v '/limine_history/' || true; }
# kept: status says protected with nothing missing (everything signed, the menu locked and enrolled, the TPM opens
# the disk), and sbctl agrees nothing is unsigned
kept() {
  local j; j=$(lab_ssh_root monarchy-encryption status --json)
  [[ -z $(unsigned) && $(jq -c '[.protected, .missing]' <<<"$j") == '[true,[]]' ]] || {
    echo "      unsigned: $(unsigned)"; echo "      status: $j"; return 1; }
}
# starts: restarts with nothing typed, started by the firmware's Limine entry (not its fallback)
starts() {
  restart_untyped || { unlock_and_wait "$LAB" 300 "$key"; return 1; }
  local cur; cur=$(lab_ssh_root efibootmgr | sed -n 's/^BootCurrent: //p')
  [[ $(lab_ssh_root efibootmgr | sed -n "s/^Boot$cur\\* \\([^\\t]*\\).*/\\1/p") == Limine ]] || { echo "      started by Boot$cur, not Limine"; return 1; }
}

checkpoint set-up build_set_up; key=$RECOVERY_KEY; mkdir -p "$shots"
[[ $(lab_ssh_root monarchy-encryption status --json | jq -c '[.protected, .missing]') == '[true,[]]' ]] && ok "set up: protected" || bad "not set up"
lab_ssh test -f /usr/share/libalpm/hooks/zz-monarchy-encryption.hook && ok "the pacman hook is installed" || bad "no pacman hook"

echo "[a kernel update]"
out=$(pkg linux-omarchy)
[[ $out == *"Keeping disk encryption's boot settings"* ]] && ok "the pacman hook ran" || bad "hook didn't run: $(tail -5 <<<"$out")"
kept && ok "everything signed, the menu locked and protected" || bad "after the kernel update"
starts && ok "starts with nothing typed, from Limine" || bad "didn't start on its own from Limine"

echo "[a limine upgrade]"
out=$(pkg limine)
order=$(grep -nE "Deploying Omarchy Limine|Keeping disk encryption" <<<"$out" | cut -d: -f1 | paste -sd' ')
[[ $(wc -w <<<"$order") == 2 && ${order%% *} -lt ${order##* } ]] && ok "our hook runs after Omarchy's, which copied an unsigned Limine" || bad "hook order: $order: $(grep -i hook <<<"$out")"
kept && ok "Limine signed and its menu enrolled again" || bad "after the limine upgrade"
starts && ok "starts with nothing typed, from Limine (not the fallback)" || bad "didn't start on its own from Limine"

echo "[omarchy-refresh-limine]"
lab_ssh "echo $LAB_PASSWORD | sudo -S -v 2>/dev/null && OMARCHY_PATH=/usr/share/omarchy omarchy-refresh-limine" >/dev/null 2>&1
lab_ssh_root grep -qx 'editor_enabled: no' /boot/limine.conf && ok "Omarchy's menu came in, and the editor is locked again" || bad "editor not locked after refresh"
kept && ok "the menu enrolled and everything signed" || bad "after refresh-limine"
lab_ssh_root systemctl reboot >/dev/null 2>&1 || true
for _ in $(seq 60); do sleep 0.5; menu_text | grep -qi "Booting automatically" && break; done
press "$LAB" down; sleep 0.3; press "$LAB" up; sleep 0.3; text=$(menu_text); cp "$shots/m.png" "$shots/menu.png"
[[ $text == *"ENTER"* && $text != *"Edit"* && $text != *"Blank Entry"* ]] && ok "the boot menu offers no Edit" || bad "menu: $text (screen: $shots/menu.png)"
press "$LAB" ret; up_untyped 120 && ok "starts with nothing typed" || { bad "didn't start on its own"; unlock_and_wait "$LAB" 300 "$key"; }

echo "[a migration: an Omarchy update (omarchy-settings rewrites its initramfs settings), then the boot image is rebuilt]"
out=$(pkg omarchy omarchy-settings) || bad "pacman -S omarchy omarchy-settings: $(tail -n 3 <<<"$out")"
lab_ssh_root limine-mkinitcpio >/dev/null 2>&1
[[ $(lab_ssh_root bash -c 'source /etc/mkinitcpio.conf.d/omarchy_hooks.conf; for f in /etc/mkinitcpio.conf.d/*.conf; do source $f; done; echo " ${HOOKS[*]} "') == *" sd-encrypt "* ]] \
  && ok "our drop-in still maps Omarchy's hooks to the systemd ones" || bad "hooks after the migration"
kept && ok "everything signed, the menu locked and protected" || bad "after the migration"
starts && ok "starts with nothing typed (the TPM needs the systemd initramfs)" || bad "didn't start on its own"

echo "[reassert by hand]"
out=$(lab_ssh_root monarchy-encryption reassert 2>&1)
[[ $out == *"boot settings checked"* && $out != *"repaired"* ]] && ok "nothing left to repair" || bad "reassert: $out"

((fail)) && { echo "RESULT: FAIL"; exit 1; }; echo "RESULT: ALL PASS"
