#!/bin/bash
# release: undoes setup in an order that never removes the last way in. A new passphrase first (unlocked by the TPM, or
# the recovery key when the TPM no longer matches), proven, then the TPM slot goes, then Secure Boot is handed back and
# this laptop's keys and hooks removed. Refusals change nothing. A released laptop can be set up again.
source "$(dirname "$0")/lib.sh"

NEW=correct-staple-disk
slots() { awk '{print $1, $2}' "$T/state/keyslots" | sort -n | paste -sd, -; }
opens() { awk -v k="$1" '$3 == k {f=1} END {exit !f}' "$T/state/keyslots"; }
line_of() { grep -n -F -- "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }
setup_done() { # a laptop through setup and the restart after it: TPM, recovery key ($KEY), no passphrase
  sandbox; me_in "$DISK_PASSPHRASE" setup --json; KEY=$(js .recovery_key); efivar SecureBoot 1; me_in "" finish
  [[ $(slots) == "2 recovery,3 tpm2" ]] || bad "setup_done: $(slots)"
}
unchanged() { [[ $(cat "$T/state/keyslots") == "$slots_before" && $(snap) == "$BEFORE" && -d $T/sbctl ]]; }
remember() { slots_before=$(cat "$T/state/keyslots"); BEFORE=$(snap); : > "$STUB_LOG"; }

echo "[nothing set up]"
sandbox; remember; me_in "$NEW" release
[[ $RC -eq 0 && $ERR == *"nothing to release"* && $(cat "$T/state/keyslots") == "$slots_before" && $(snap) == "$BEFORE" ]] && ok "nothing to do" || bad "rc $RC: $ERR"

echo "[a laptop that's set up]"
setup_done; : > "$STUB_LOG"; me_in "$NEW" release
[[ $RC -eq 0 && $ERR == *"released"* ]] && ok "release succeeds" || { bad "rc $RC"; sed 's/^/      /' <<<"$ERR"; }
[[ $(slots) == "0 password,2 recovery" ]] && opens "$NEW" && opens "$KEY" && ok "the new passphrase and the recovery key open the disk; the TPM slot is gone" || bad "slots: $(slots)"
check "the passphrase was added with the TPM as the unlock" called "cryptsetup luksAddKey --token-only --token-type systemd-tpm2 /dev/vda2 /dev/stdin"
a=$(line_of "luksAddKey"); w=$(line_of "--wipe-slot=3 "); r=$(line_of "sbctl reset")
[[ -n $a && -n $w && -n $r && $a -lt $w && $w -lt $r ]] && ok "passphrase first, then the TPM slot, then Secure Boot" || bad "order: add $a, wipe $w, reset $r"
grep -qF "$NEW" "$STUB_LOG" && bad "the passphrase reached a command line" || ok "the passphrase never reaches a command line or log"
[[ ! -e $T/efivars/PK-$G && ! -e $T/sbctl ]] && ok "the firmware has no platform key, this laptop's keys are gone" || bad "keys left"
[[ ! -e $T/etc/boot/hooks/post.d/85-monarchy-encryption-editor && ! -e $T/etc/boot/hooks/post.d/95-monarchy-encryption-fallback ]] && ok "our Limine hooks are unlinked" || bad "hooks left"
me status --json
[[ $(js '[.disk.tpm_enrolled, .disk.passphrase, .secure_boot.setup_mode, .secure_boot.own_keys] | map(tostring) | join(" ")') == "false true true false" ]] \
  && ok "status: no TPM, a passphrase, the firmware in setup mode" || bad "status: $OUT"
remember; me_in "" reassert
[[ $RC -eq 0 && $ERR == *"setup hasn't run"* && $(snap) == "$BEFORE" ]] && ok "updates leave it alone (reassert has nothing to do)" || bad "reassert: $ERR"
me_in "" release; [[ $RC -eq 0 && $ERR == *"nothing to release"* ]] && ok "release again: nothing to do" || bad "again: $ERR"
[[ -e $T/state/immutable/KEK-$G ]] || bad "the stub should leave KEK immutable after sbctl reset"
me_in "$NEW" setup --json
[[ $RC -eq 0 && $(js .done) == false ]] && called "sbctl create-keys" && called "sbctl enroll-keys" && ok "setup takes it back (new keys; the firmware is in setup mode)" || bad "setup again: rc $RC: $ERR"
check "the leftover KEK is made writable before enrolling (sbctl reset leaves it, immutable)" called "chattr -i $T/efivars/KEK-$G"

echo "[the firmware changed since setup: the TPM no longer opens the disk]"
setup_done; sed -i 's/ tpm2 -$/ tpm2 stale/' "$T/state/keyslots"; remember
me_in "$NEW" release
[[ $RC -eq 1 && $ERR == *"recovery key"* ]] && unchanged && ok "without the recovery key: asks for it, nothing changed" || bad "rc $RC: $ERR"
me_in "$NEW"$'\n'"$KEY" release
[[ $RC -eq 0 && $(slots) == "0 password,2 recovery" ]] && opens "$NEW" && ok "with the recovery key as the second line: released" || bad "rc $RC: $ERR $(slots)"
check "the recovery key unlocked the change" called "cryptsetup luksAddKey --key-file=/dev/fd/"

echo "[the passphrase was kept by setup]"
sandbox; me_in "$DISK_PASSPHRASE" setup --json; efivar SecureBoot 1
sed -i '/ tpm2 /d' "$T/state/keyslots"; me_in "$DISK_PASSPHRASE" setup >/dev/null; : > "$STUB_LOG"   # finished by hand
me_in "" release
[[ $RC -eq 0 && $ERR == *"keeping it"* && $(slots) == "0 password,2 recovery" ]] && ! called "luksAddKey" && ok "no new passphrase asked; the TPM slot goes" || bad "rc $RC: $ERR $(slots)"

echo "[before the restart after setup (Secure Boot keys enrolled, the one-time unlock)]"
sandbox; me_in "$DISK_PASSPHRASE" setup >/dev/null; me_in "" release
[[ $RC -eq 0 && ! -e $T/efivars/PK-$G && ! -e $T/sbctl && $(slots) == "0 password,2 recovery" ]] && ok "Secure Boot handed back; the one-time unlock removed, the passphrase kept" || bad "rc $RC: $ERR $(slots)"
[[ ! -e $T/etc/systemd/system/multi-user.target.wants/monarchy-encryption-finish.service ]] && ok "nothing left to run at the next start" || bad "finish still linked"

echo "[refusals]"
setup_done; remember; me_in "" release
[[ $RC -eq 1 && $ERR == *"new disk passphrase"* ]] && unchanged && ok "no new passphrase: says how to give one, nothing changed" || bad "rc $RC: $ERR"
STUB_RESET_FAIL=1 me_in "$NEW" release
[[ $RC -eq 1 && $ERR == *"firmware settings"* && $(slots) == "0 password,2 recovery" ]] && opens "$NEW" \
  && ok "sbctl reset fails: says so; the disk already opens with the new passphrase" || bad "reset fail: rc $RC: $ERR"
me_in "$NEW" release --bogus; [[ $RC -eq 1 && $ERR == Usage:* ]] && ok "unknown options: usage" || bad "--bogus"
result
