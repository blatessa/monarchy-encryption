#!/bin/bash
# status --json: one answer to "is this disk protected the way it should be", with what's missing, following a laptop
# from a stock install to the end of setup and back when something changes. Read-only; null where only root can know.
source "$(dirname "$0")/lib.sh"

st() { me status --json; }
writes() { grep -E "cryptsetup (luksAddKey|luksKillSlot)|systemd-cryptenroll|sbctl (sign|enroll-keys|create-keys)|limine-update" "$STUB_LOG"; }

echo "[a stock install]"
sandbox; st
[[ $RC -eq 0 && $(js '[.schema, .protected] | @tsv') == $'1\tfalse' ]] && ok "schema 1, not protected" || bad "rc $RC: $OUT"
[[ $(js '.missing | join(" ")') == "disk.systemd_initramfs disk.tpm_unlock disk.recovery_key disk.no_passphrase secure_boot.enabled secure_boot.own_keys secure_boot.boot_files_signed boot_menu.editor_locked boot_menu.config_protected" ]] \
  && ok "missing names everything setup would do (the stock fallback loader is fine without a menu to protect)" || bad "missing: $(js .missing)"
[[ $(js '.disk | [.encrypted, .tpm_enrolled, .tpm_pcrs, .passphrase] | map(tostring) | join(" ")') == "true false null true" ]] \
  && ok "encrypted, no TPM, the passphrase" || bad "disk: $(js .disk)"

echo "[after the first run]"
me_in "$DISK_PASSPHRASE" setup >/dev/null; key=$OUT; st
[[ $(js .protected) == false && $(js '.missing | join(" ")') == "disk.tpm_unlock disk.no_passphrase secure_boot.enabled" ]] \
  && ok "missing: the TPM, the passphrase still there, Secure Boot not on until the restart" || bad "missing: $(js .missing)"
[[ $(js '[.disk.recovery_key, .secure_boot.boot_files_signed] | map(tostring) | join(" ")') == "true true" ]] && ok "a recovery key, everything signed" || bad "$OUT"

echo "[after the second run]"
efivar SecureBoot 1; me_in "$key" setup >/dev/null; : > "$STUB_LOG"; BEFORE=$(snap); slots=$(cat "$T/state/keyslots"); st
[[ $(js .protected) == true && $(js '.missing | length') == 0 ]] && ok "protected, nothing missing" || bad "$OUT"
[[ $(js '.disk | [.tpm_unlock, .tpm_enrolled, (.tpm_pcrs | tostring), .recovery_key, .passphrase] | map(tostring) | join(" ")') == "true true [7] true false" ]] \
  && ok "the TPM opens the disk, bound to PCR 7; a recovery key; no passphrase" || bad "disk: $(js .disk)"
[[ $(snap) == "$BEFORE" && $(cat "$T/state/keyslots") == "$slots" && -z $(writes) ]] && ok "status changes nothing" || bad "status wrote: $(writes)"
me status; [[ $RC -eq 0 && $OUT == "Protected:              yes"* && $OUT == *"boot files signed:    yes"* ]] && ok "plain: Protected: yes" || bad "plain: $OUT"

echo "[the firmware changed since (PCR 7 differs)]"
sed -i 's/ tpm2 -$/ tpm2 stale/' "$T/state/keyslots"; st
[[ $(js .protected) == false && $(js '.missing | join(" ")') == "disk.tpm_unlock" && $(js .disk.tpm_enrolled) == true ]] \
  && ok "enrolled but no longer opening the disk: not protected, and says which" || bad "stale: $OUT"
me status; [[ $OUT == *"Protected:              no: disk.tpm_unlock"* && $OUT == *"run setup with the recovery key"* ]] && ok "plain: says what to do" || bad "plain: $OUT"
sed -i 's/ tpm2 stale$/ tpm2 -/' "$T/state/keyslots"

echo "[a boot image that isn't signed]"
echo "rebuilt behind our back" > "$T/boot/EFI/Linux/omarchy_linux-omarchy.efi"; st
[[ $(js .protected) == false && $(js '.missing | join(" ")') == "secure_boot.boot_files_signed" ]] && ok "noticed" || bad "unsigned: $OUT"

echo "[without root]"
me_user status --json
[[ $RC -eq 0 && $(js .protected) == null && $(js '.missing | length') == 0 ]] && ok "protected unknown, not a guess; nothing listed as missing" || bad "user: $OUT"
[[ $(js '[(.disk | del(.provisioning_pending))[], .secure_boot.own_keys, .secure_boot.boot_files_signed] | map(tostring) | unique | join(" ")') == "null" ]] \
  && ok "the disk and keys are null for a user" || bad "user disk: $(js .disk)"
[[ $(js .disk.provisioning_pending) == false ]] && ok "whether first-boot setup is pending shows for a user too (file names only)" || bad "user provisioning: $(js .disk)"
[[ $(js .secure_boot.enabled) == true ]] && ok "the firmware's own flags still show (world-readable)" || bad "user sb: $(js .secure_boot)"
me_user status; [[ $OUT == "Protected:              unknown (run as root)"* ]] && ok "plain: unknown (run as root)" || bad "plain user: $OUT"
sandbox; me_user status --json
[[ $(jq -c '[.protected, .missing]' <<<"$OUT") == '[false,["secure_boot.enabled"]]' ]] \
  && ok "with Secure Boot off a user already sees it isn't protected" || bad "user, stock: $OUT"
result
