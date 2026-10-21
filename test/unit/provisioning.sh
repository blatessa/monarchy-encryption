#!/bin/bash
# While Omarchy's first-boot provisioning is pending (a deferred install or a factory reset), the disk unlocks with a
# key file only the busybox initramfs can use (findings.md): setup refuses and changes nothing, reassert leaves the
# boot settings alone, status says so. Once provisioning is done, setup goes ahead.
source "$(dirname "$0")/lib.sh"

P=var/lib/omarchy/provisioning
# stage MARKER: one of the files Omarchy's deferred install and factory reset leave behind
stage() { mkdir -p "$T/$(dirname "$1")"; echo "staged" > "$T/$1"; }

for m in "$P/pending" etc/omarchy/provisioning.key etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf \
  etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf; do
  echo "[$m]"
  sandbox; stage "$m"; BEFORE=$(snap); slots=$(cat "$T/state/keyslots")
  me_in "$DISK_PASSPHRASE" setup
  [[ $RC -eq 1 && $ERR == *"first-boot setup hasn't finished"* && $ERR == *"Nothing was changed"* ]] && ok "setup refuses, says why" || bad "rc $RC: $ERR"
  [[ $(snap) == "$BEFORE" && $(cat "$T/state/keyslots") == "$slots" ]] && ! called "limine-update" \
    && ok "nothing changed: no initramfs switch, no keys, no keyslot" || bad "changed: $(cat "$STUB_LOG")"
done

echo "[status]"
me status --json
[[ $(js .disk.provisioning_pending) == true && $(js .protected) == false && $(js '.missing | index("disk.no_provisioning_pending") != null') == true ]] \
  && ok "pending, not protected, and listed as missing" || bad "status: $OUT"
me_user status --json; [[ $(js .disk.provisioning_pending) == true ]] && ok "a user sees it too" || bad "user: $OUT"
me status; [[ $OUT == *"first-boot setup:     pending"* ]] && ok "plain status says to finish it first" || bad "plain: $OUT"

echo "[reassert on a set-up laptop that a factory reset left pending]"
sandbox; me setup >/dev/null; stage "$P/pending"; stage etc/omarchy/provisioning.key
rm "$T/etc/mkinitcpio.conf.d/zz-monarchy-encryption.conf"; BEFORE=$(snap); : > "$STUB_LOG"
me_in "" reassert
[[ $RC -eq 0 && $ERR == *"first-boot setup is pending"* && $(snap) == "$BEFORE" ]] && ! called "limine-update" \
  && ok "stands down: the systemd initramfs isn't put back while the key file unlocks the disk" || bad "reassert: rc $RC: $ERR"

echo "[once provisioning is done]"
sandbox; stage "$P/pending"; me_in "$DISK_PASSPHRASE" setup >/dev/null
rm -r "$T/$P/pending"
me_in "$DISK_PASSPHRASE" setup --json
[[ $RC -eq 0 && $(js .done) == false && $(js .recovery_key) =~ ^[a-z] ]] && ok "setup goes ahead" || bad "rc $RC: $ERR"
result
