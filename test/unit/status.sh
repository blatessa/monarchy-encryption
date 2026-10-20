#!/bin/bash
# status --json: one answer to "is this disk protected the way it should be", with what's missing, following a laptop
# from a stock install through setup and the restart after it and back when something changes. Read-only; null where only root can know.
source "$(dirname "$0")/lib.sh"

st() { me status --json; }
writes() { grep -E "cryptsetup (luksAddKey|luksKillSlot)|systemd-cryptenroll|systemd-pcrlock (lock|make|remove)|limine-update" "$STUB_LOG"; }

echo "[a stock install]"
sandbox; st
[[ $RC -eq 0 && $(js '[.schema, .protected] | @tsv') == $'2\tfalse' ]] && ok "schema 2, not protected" || bad "rc $RC: $OUT"
[[ $(js '.missing | join(" ")') == "disk.systemd_initramfs disk.tpm_unlock disk.recovery_key disk.no_passphrase boot_menu.editor_locked boot_menu.config_protected tpm_policy.current" ]] \
  && ok "missing names everything setup would do (the stock fallback loader is fine without a menu to protect)" || bad "missing: $(js .missing)"
[[ $(js '[.disk.encrypted, .disk.tpm_enrolled, .disk.passphrase, .tpm_policy.exists, .tpm_policy.pcrs] | map(tostring) | join(" ")') == "true false true false null" ]] \
  && ok "encrypted, no TPM, the passphrase, no policy" || bad "disk: $(js .disk) $(js .tpm_policy)"

echo "[after setup, before the restart]"
me_in "$DISK_PASSPHRASE" setup >/dev/null; st
[[ $(js .protected) == false && $(js '.missing | join(" ")') == "disk.tpm_unlock disk.no_one_time_unlock disk.no_passphrase tpm_policy.current" ]] \
  && ok "missing: the TPM, the one-time unlock and the passphrase still there, no policy until the restart" || bad "missing: $(js .missing)"
[[ $(js '[.disk.one_time_unlock, .disk.tpm_enrolled, .disk.recovery_key] | map(tostring) | join(" ")') == "true false true" ]] \
  && ok "the one-time unlock isn't the TPM unlock; a recovery key" || bad "disk: $(js .disk)"
me status; [[ $OUT == *"opens by itself once: yes (setup isn't finished: restart the laptop)"* && $OUT == *"TPM policy:             none yet (made at the restart)"* ]] \
  && ok "plain: says to restart" || bad "plain: $OUT"

echo "[after the restart]"
restart >/dev/null; : > "$STUB_LOG"; BEFORE=$(snap); slots=$(cat "$T/state/keyslots"); st
[[ $(js .protected) == true && $(js '.missing | length') == 0 ]] && ok "protected, nothing missing" || bad "$OUT"
[[ $(js '.disk | [.tpm_unlock, .tpm_enrolled, .one_time_unlock, .recovery_key, .passphrase] | map(tostring) | join(" ")') == "true true false true false" ]] \
  && ok "the TPM opens the disk; no one-time unlock; a recovery key; no passphrase" || bad "disk: $(js .disk)"
[[ $(js '.tpm_policy | [.exists, (.pcrs | tostring), .current] | map(tostring) | join(" ")') == "true [4,11] true" ]] \
  && ok "the policy covers the boot files, over PCR 4 and 11" || bad "tpm_policy: $(js .tpm_policy)"
[[ $(snap) == "$BEFORE" && $(cat "$T/state/keyslots") == "$slots" && -z $(writes) ]] && ok "status changes nothing" || bad "status wrote: $(writes)"
me status; [[ $RC -eq 0 && $OUT == "Protected:              yes"* && $OUT == *"covers boot files:   yes"* ]] && ok "plain: Protected: yes" || bad "plain: $OUT"

echo "[the TPM no longer opens the disk]"
sed -i 's/ tpm2 -$/ tpm2 stale/' "$T/state/keyslots"; st
[[ $(js .protected) == false && $(js '.missing | join(" ")') == "disk.tpm_unlock" && $(js .disk.tpm_enrolled) == true ]] \
  && ok "enrolled but no longer opening the disk: not protected, and says which" || bad "stale: $OUT"
me status; [[ $OUT == *"Protected:              no: disk.tpm_unlock"* && $OUT == *"run setup with the recovery key"* ]] && ok "plain: says what to do" || bad "plain: $OUT"
sed -i 's/ tpm2 stale$/ tpm2 -/' "$T/state/keyslots"

echo "[without root]"
me_user status --json
[[ $RC -eq 0 && $(js .protected) == null && $(js '.missing | length') == 0 ]] && ok "protected unknown, not a guess; nothing listed as missing" || bad "user: $OUT"
[[ $(js '[(.disk | del(.provisioning_pending))[], .tpm_policy[], .boot_menu[]] | map(tostring) | unique | join(" ")') == "null" ]] \
  && ok "the disk, the policy and the menu are null for a user" || bad "user: $OUT"
[[ $(js .disk.provisioning_pending) == false ]] && ok "whether first-boot setup is pending shows for a user too (file names only)" || bad "user provisioning: $(js .disk)"
me_user status; [[ $OUT == "Protected:              unknown (run as root)"* ]] && ok "plain: unknown (run as root)" || bad "plain user: $OUT"
result
