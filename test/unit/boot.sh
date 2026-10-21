#!/bin/bash
# setup's boot part: a boot menu that can't be edited or swapped (its checksum enrolled into Limine, which the TPM
# measures), and the TPM policy following the boot files through Limine's hooks: updates and snapshots, the files
# that started kept allowed. Refusals change nothing.
source "$(dirname "$0")/lib.sh"

line_of() { grep -n -F -- "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }   # first line in the call log with this text
hash_of() { sha256sum "$1" | cut -d' ' -f1; }
covers() { grep -qx "${2:-pe} $(hash_of "$1")" "$T/state/policy-covers"; }   # the policy pcrlock wrote allows this file
set_up() { sandbox; me_in "$DISK_PASSPHRASE" setup --json; KEY=$(js .recovery_key); restart; }

echo "[setup]"
sandbox
me setup
[[ $RC -eq 0 ]] && ok "setup succeeds" || { bad "setup: rc $RC"; sed 's/^/      /' <<<"$OUT"; }
[[ $(head -2 "$T/boot/limine.conf" | tail -1) == "editor_enabled: no" ]] && ok "boot menu editor off, above the entries" || bad "editor line: $(grep -n editor "$T/boot/limine.conf")"
check "menu checksum enrollment on in /etc/default/limine" grep -qx 'ENABLE_ENROLL_LIMINE_CONFIG=yes' "$T/etc/default/limine"
for h in 85-monarchy-encryption-editor:limine-editor 95-monarchy-encryption-fallback:limine-fallback 96-monarchy-encryption-policy:limine-policy; do
  [[ $(readlink "$T/etc/boot/hooks/post.d/${h%%:*}") == "$REPO/hooks/${h#*:}" ]] && ok "Limine hook ${h%%:*} linked" || bad "hook ${h%%:*}"
done
check "the fallback loader is the enrolled Limine, not the plain one" cmp -s "$T/boot/EFI/limine/limine_x64.efi" "$T/boot/EFI/BOOT/BOOTX64.EFI"
grep -q "^enrolled $(b2sum "$T/boot/limine.conf" | cut -d' ' -f1)$" "$T/boot/EFI/limine/limine_x64.efi" \
  && ok "Limine carries the checksum of the menu as written (editor line included)" || bad "enrolled checksum"
grep -qE "sbctl|efi-updatevar|KeyTool" "$STUB_LOG" && bad "Secure Boot touched" || ok "the firmware's Secure Boot keys are left as they are"
me status --json
[[ $(js '[.schema, .boot_menu.editor_locked, .boot_menu.config_protected, .boot_menu.fallback_protected] | map(tostring) | join(" ")') == "2 true true true" ]] \
  && ok "status: menu locked, protected, fallback protected" || bad "boot_menu: $OUT"
[[ $(js '.tpm_policy | [.exists, .current] | map(tostring) | join(" ")') == "false false" ]] && ok "status: no TPM policy until the restart" || bad "tpm_policy: $(js .tpm_policy)"

echo "[setup again]"
: > "$STUB_LOG"; before_editor=$(grep -c '^editor_enabled' "$T/boot/limine.conf")
me setup
[[ $RC -eq 0 ]] && ok "re-running succeeds" || bad "rerun: rc $RC: $OUT"
called "limine-update" && bad "rebuilt for nothing" || ok "boot files not rebuilt again"
[[ $(grep -c '^editor_enabled' "$T/boot/limine.conf") == "$before_editor" && $(grep -c '^ENABLE_ENROLL' "$T/etc/default/limine") == 1 ]] \
  && ok "no duplicated settings" || bad "duplicates"

echo "[the policy follows the boot files]"
set_up
covers "$T/boot/EFI/limine/limine_x64.efi" && covers "$T/boot/EFI/Linux/omarchy_linux-omarchy.efi" uki \
  && ok "the restart: the policy allows the Limine and boot image that started" || bad "policy covers: $(cat "$T/state/policy-covers")"
old_limine=$(hash_of "$T/boot/EFI/limine/limine_x64.efi"); old_uki=$(hash_of "$T/boot/EFI/Linux/omarchy_linux-omarchy.efi")
: > "$STUB_LOG"; unshare -r limine-update >/dev/null 2>&1   # a kernel update, a snapshot (limine-snapper-sync), omarchy-refresh-limine
e=$(line_of "90-limine-enroll"); p=$(line_of "make-policy")
covers "$T/boot/EFI/limine/limine_x64.efi" && covers "$T/boot/EFI/Linux/omarchy_linux-omarchy.efi" uki \
  && ok "an update through Limine's tools: the policy allows the new files" || bad "after update: $(cat "$T/state/policy-covers")"
grep -qx "pe $old_limine" "$T/state/policy-covers" && grep -qx "uki $old_uki" "$T/state/policy-covers" \
  && ok "and still the ones that started (an update keeps the running start recognised)" || bad "booted variant lost"
check "with the recovery PIN, so it works from a start that missed the policy" called "--recovery-pin=query"
me status --json; [[ $(js '[.protected, .tpm_policy.current] | map(tostring) | join(" ")') == "true true" ]] && ok "status: protected, the policy covers the boot files" || bad "status: $OUT"
for i in 1 2; do unshare -r limine-update >/dev/null 2>&1; done
[[ $(grep -c '^pe ' "$T/state/policy-covers") -le 2 && $(grep -c '^uki ' "$T/state/policy-covers") == 2 ]] \
  && ok "several updates before a restart: only the files that started and the newest are allowed" || bad "variants: $(cat "$T/state/policy-covers")"
restart
[[ $(grep -c '^pe ' "$T/state/policy-covers") == 1 && $(grep -c '^uki ' "$T/state/policy-covers") == 1 ]] && covers "$T/boot/EFI/limine/limine_x64.efi" \
  && ok "the next start: only the files that started" || bad "after restart: $(cat "$T/state/policy-covers")"

echo "[boot files changed behind Limine's tools]"
echo "rebuilt behind our back" > "$T/boot/EFI/Linux/omarchy_linux-omarchy.efi"; me status --json
[[ $(js '[.protected, .tpm_policy.current, (.missing | join(" "))] | map(tostring) | join(" ")') == "false false tpm_policy.current" ]] \
  && ok "status: not protected, the policy doesn't cover the boot image" || bad "unnoticed: $OUT"
me_in "" reassert; me status --json
[[ $(js .tpm_policy.current) == true ]] && ok "reassert brings the policy up to date" || bad "reassert: $ERR"

echo "[the policy can't be written]"
set_up; echo "another PIN" > "$T/state/nv-pin"; : > "$STUB_LOG"
OUT=$(unshare -r limine-update 2>&1); rc=$?
[[ $rc -eq 0 && $OUT == *"TPM policy couldn't be updated"*"recovery key at the next start"* ]] \
  && ok "Limine's tools still succeed; the hook says the next start needs the recovery key" || bad "rc $rc: $OUT"
me status --json; [[ $(js .tpm_policy.current) == false ]] && ok "status: the policy doesn't cover the boot files" || bad "status: $OUT"

echo "[before the restart after setup]"
sandbox; me setup >/dev/null; : > "$STUB_LOG"; unshare -r limine-update >/dev/null 2>&1
called "make-policy" && bad "a policy made from a start that didn't use these boot files" || ok "the hook does nothing until the restart makes the first policy"

echo "[refusals]"
sandbox; rm "$T/boot/limine.conf"; me setup
[[ $RC -ne 0 && $OUT == *"no Limine menu"* ]] && ok "no Limine menu: refused" || bad "no limine.conf: rc $RC: $OUT"
sandbox; export STUB_LIMINE_UPDATE_FAIL=1; me setup
[[ $RC -ne 0 && $OUT == *"limine-update"* && $OUT == *"Failed to build"* ]] && ok "rebuilding fails: refused, with the tool's error" || bad "limine-update fail: rc $RC: $OUT"
called "--tpm2-device" && bad "the TPM enrolled after a failed rebuild" || ok "nothing enrolled"
unset STUB_LIMINE_UPDATE_FAIL
sandbox; me_user setup; [[ $RC -ne 0 && $OUT == *"sudo"* ]] && ok "needs root" || bad "as user: $OUT"

echo "[Omarchy's own settings]"
sandbox
sed -i '1i editor_enabled: yes' "$T/boot/limine.conf"; echo 'ENABLE_ENROLL_LIMINE_CONFIG=no' >> "$T/etc/default/limine"
me setup
[[ $(grep -c '^editor_enabled' "$T/boot/limine.conf") == 1 ]] && check "an existing editor setting is switched off, not duplicated" grep -qx 'editor_enabled: no' "$T/boot/limine.conf" || bad "editor duplicated"
[[ $(grep -c '^ENABLE_ENROLL' "$T/etc/default/limine") == 1 ]] && check "an existing enroll setting is switched on, not duplicated" grep -qx 'ENABLE_ENROLL_LIMINE_CONFIG=yes' "$T/etc/default/limine" || bad "enroll duplicated"
check "the rest of /etc/default/limine is untouched" grep -qF 'KERNEL_CMDLINE[default]+="cryptdevice=' "$T/etc/default/limine"

echo "[the fallback hook]"
cp "$T/state/limine-stock.efi" "$T/boot/EFI/BOOT/BOOTX64.EFI"   # what limine-install does on every update
unshare -r "$T/etc/boot/hooks/post.d/95-monarchy-encryption-fallback" && cmp -s "$T/boot/EFI/limine/limine_x64.efi" "$T/boot/EFI/BOOT/BOOTX64.EFI" \
  && ok "replaces a plain fallback with the enrolled Limine" || bad "hook didn't replace the fallback"
me status --json; [[ $(js .boot_menu.fallback_protected) == true ]] && ok "status: fallback protected again" || bad "fallback status"
cp "$T/state/limine-stock.efi" "$T/boot/EFI/BOOT/BOOTX64.EFI"; me status --json
[[ $(js .boot_menu.fallback_protected) == false ]] && ok "status notices a plain fallback" || bad "plain fallback unnoticed"
echo "editor_enabled: yes" >> "$T/boot/limine.conf"; me status --json
[[ $(js .boot_menu.config_protected) == false ]] && ok "status notices a menu changed since it was enrolled" || bad "changed menu unnoticed"

echo "[status without root]"
me_user status --json
[[ $(js '[.boot_menu.editor_locked, .boot_menu.config_protected, .tpm_policy.exists, .tpm_policy.current] | map(tostring) | join(" ")') == "null null null null" ]] \
  && ok "what only root can check is null, not a guess" || bad "user status: $OUT"
me_user status; [[ $RC -eq 0 && $OUT == *"TPM policy:"* && $OUT == *"unknown (run as root)"* ]] && ok "plain status" || bad "plain: $OUT"
result
