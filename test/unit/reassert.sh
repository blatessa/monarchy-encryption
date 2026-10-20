#!/bin/bash
# reassert, run by a pacman hook after updates: puts back what an update undid (as observed in the lab: findings.md,
# "Updates after setup") with no key and no question, changes nothing when nothing changed, and leaves keys and the
# TPM's keyslots alone. Limine's hooks keep the menu locked and the TPM policy current through Limine's own rebuilds.
source "$(dirname "$0")/lib.sh"

editor_locked() { grep -qx 'editor_enabled: no' "$T/boot/limine.conf"; }
enrolled() { grep -qx "enrolled $(b2sum "$T/boot/limine.conf" | cut -d' ' -f1)" "$T/boot/EFI/limine/limine_x64.efi"; }
policy_current() { me status --json; [[ $(js .tpm_policy.current) == true ]]; }
protected() { editor_locked && enrolled && cmp -s "$T/boot/EFI/limine/limine_x64.efi" "$T/boot/EFI/BOOT/BOOTX64.EFI"; }
reassert() { : > "$STUB_LOG"; me_in "" reassert; }   # as the pacman hook runs it: no input

echo "[before setup]"
sandbox; BEFORE=$(snap); reassert
[[ $RC -eq 0 && $ERR == *"setup hasn't run"* && $(snap) == "$BEFORE" && -z $(grep -v '^logger ' "$STUB_LOG") ]] && ok "nothing to do, nothing changed" || bad "rc $RC: $ERR"

echo "[after setup, nothing changed]"
me setup >/dev/null; restart >/dev/null; reassert
[[ $RC -eq 0 && $ERR == *"boot settings checked"* && $ERR != *"repaired"* ]] && ok "checked, nothing to repair" || bad "rc $RC: $ERR"
called "limine-update" && bad "rebuilt for nothing" || ok "no rebuild"
called "make-policy" && bad "policy rewritten for nothing" || ok "the policy already covers the boot files: left alone"
for h in 85-monarchy-encryption-editor:limine-editor 95-monarchy-encryption-fallback:limine-fallback 96-monarchy-encryption-policy:limine-policy; do
  [[ $(readlink "$T/etc/boot/hooks/post.d/${h%%:*}") == "$REPO/hooks/${h#*:}" ]] && ok "Limine hook ${h%%:*} linked" || bad "hook ${h%%:*}"
done

echo "[omarchy-refresh-limine: Omarchy's menu copied over ours, then limine-update]"
cp "$FIX/boot/limine.conf" "$T/boot/limine.conf"; unshare -r limine-update >/dev/null
editor_locked && enrolled && ok "the editor hook locks the menu before its checksum is enrolled, with no reassert" || bad "menu after refresh: $(head -3 "$T/boot/limine.conf")"

echo "[a limine upgrade: Omarchy's hook copies a plain Limine (no menu checksum) over the enrolled one]"
cp "$T/state/limine-stock.efi" "$T/boot/EFI/limine/limine_x64.efi"; reassert
[[ $RC -eq 0 && $ERR == *"repaired and rebuilt"* ]] && called "limine-update" && protected && ok "the menu's checksum enrolled again" || bad "rc $RC: $ERR"
policy_current && ok "and the TPM policy covers the new Limine" || bad "policy: $(js .tpm_policy)"

echo "[settings an update undid]"
sed -i 's/^ENABLE_ENROLL_LIMINE_CONFIG=yes/ENABLE_ENROLL_LIMINE_CONFIG=no/' "$T/etc/default/limine"; reassert
grep -qx 'ENABLE_ENROLL_LIMINE_CONFIG=yes' "$T/etc/default/limine" && protected && ok "menu checksum enrollment back on" || bad "enroll setting: $ERR"
rm "$T/etc/mkinitcpio.conf.d/zz-monarchy-encryption.conf"; reassert
[[ -f $T/etc/mkinitcpio.conf.d/zz-monarchy-encryption.conf ]] && called "limine-update" && ok "the systemd initramfs drop-in back, boot image rebuilt" || bad "drop-in: $ERR"
rm "$T/etc/boot/hooks/post.d/85-monarchy-encryption-editor"; reassert
[[ -L $T/etc/boot/hooks/post.d/85-monarchy-encryption-editor ]] && ok "a missing hook is linked (laptops set up by an older version get new ones)" || bad "hook not relinked"
echo "rebuilt behind our back" > "$T/boot/EFI/Linux/omarchy_linux-omarchy.efi"; reassert
called "make-policy" && policy_current && ok "a boot image Limine's hooks didn't see: the policy covers it" || bad "policy: $ERR"
echo "another PIN" > "$T/state/nv-pin"; echo "again" >> "$T/boot/EFI/Linux/omarchy_linux-omarchy.efi"; reassert
[[ $RC -eq 0 && $ERR == *"TPM policy couldn't be updated"*"recovery key"* ]] && ok "a policy that can't be written: a warning, not a failed update" || bad "rc $RC: $ERR"
rm "$T/state/nv-pin"

echo "[keys and the TPM are left alone]"
sandbox; me_in "$DISK_PASSPHRASE" setup >/dev/null; restart >/dev/null
sed -i 's/ tpm2 -$/ tpm2 stale/' "$T/state/keyslots"; slots=$(cat "$T/state/keyslots"); reassert
[[ $RC -eq 0 && $ERR == *"TPM no longer opens the disk"* && $ERR == *"recovery key"* && $(cat "$T/state/keyslots") == "$slots" ]] \
  && ok "a TPM that no longer matches is reported, not touched" || bad "stale TPM: rc $RC: $ERR"
grep -qE "systemd-cryptenroll|cryptsetup (luksAddKey|luksKillSlot)" "$STUB_LOG" && bad "keys touched: $(cat "$STUB_LOG")" || ok "no key or keyslot touched"

echo "[refusals]"
me_in "" reassert --bogus; [[ $RC -eq 1 && $ERR == Usage:* ]] && ok "unknown options: usage" || bad "--bogus: rc $RC"
sandbox; me setup >/dev/null; restart >/dev/null; echo "root  /dev/vda2  /etc/keyfile  luks" > "$T/etc/crypttab"; BEFORE=$(snap); reassert
[[ $RC -eq 1 && $ERR == *"describes the disk 'root' differently"* && $(snap) == "$BEFORE" ]] && ok "a crypttab someone else changed: says so, changes nothing" || bad "conflict: rc $RC: $ERR"

echo "[the pacman hook]"
H="$REPO/packaging/monarchy-encryption.hook"
inst=$(sed -n 's|.*packaging/monarchy-encryption.hook" "$pkgdir/usr/share/libalpm/hooks/\([^"]*\)".*|\1|p' "$REPO/packaging/PKGBUILD")
[[ -n $inst && $inst > 99-omarchy-limine.hook ]] && ok "installed as $inst: runs after Omarchy's 99-omarchy-limine" || bad "hook name: '$inst'"
grep -qx 'Exec = /usr/bin/monarchy-encryption reassert' "$H" && grep -qx 'When = PostTransaction' "$H" && ok "runs reassert after the transaction" || bad "hook action"
for t in 'limine\*' 'omarchy\*' 'usr/lib/modules/\*/vmlinuz' 'usr/lib/initcpio/\*'; do grep -qx "Target = $t" "$H" || bad "no trigger for $t"; done; ok "triggers on Limine, Omarchy, kernels and initramfs hooks"
result
