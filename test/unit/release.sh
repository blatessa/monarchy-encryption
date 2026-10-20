#!/bin/bash
# release: undoes setup in an order that never removes the last way in. A new passphrase first (unlocked by the TPM, or
# the recovery key when the TPM no longer matches), proven, then the TPM slot goes, then the TPM policy and what kept it
# up to date. Refusals change nothing. A released laptop can be set up again.
source "$(dirname "$0")/lib.sh"

NEW=correct-staple-disk
slots() { awk '{print $1, $2}' "$T/state/keyslots" | sort -n | paste -sd, -; }
opens() { awk -v k="$1" '$3 == k {f=1} END {exit !f}' "$T/state/keyslots"; }
line_of() { grep -n -F -- "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }
setup_done() { # a laptop through setup and the restart after it: TPM, recovery key ($KEY), no passphrase
  sandbox; me_in "$DISK_PASSPHRASE" setup --json; KEY=$(js .recovery_key); restart
  [[ $(slots) == "2 recovery,3 tpm2" ]] || bad "setup_done: $(slots)"
}
unchanged() { [[ $(cat "$T/state/keyslots") == "$slots_before" && $(snap) == "$BEFORE" ]]; }
remember() { slots_before=$(cat "$T/state/keyslots"); BEFORE=$(snap); : > "$STUB_LOG"; }

echo "[nothing set up]"
sandbox; remember; me_in "$NEW" release
[[ $RC -eq 0 && $ERR == *"nothing to release"* && $(cat "$T/state/keyslots") == "$slots_before" && $(snap) == "$BEFORE" ]] && ok "nothing to do" || bad "rc $RC: $ERR"

echo "[a laptop that's set up]"
setup_done; : > "$STUB_LOG"; me_in "$NEW" release
[[ $RC -eq 0 && $ERR == *"released"* ]] && ok "release succeeds" || { bad "rc $RC"; sed 's/^/      /' <<<"$ERR"; }
[[ $(slots) == "0 password,2 recovery" ]] && opens "$NEW" && opens "$KEY" && ok "the new passphrase and the recovery key open the disk; the TPM slot is gone" || bad "slots: $(slots)"
check "the passphrase was added with the TPM as the unlock" called "cryptsetup luksAddKey --token-only --token-type systemd-tpm2 /dev/vda2 /dev/stdin"
a=$(line_of "luksAddKey"); w=$(line_of "--wipe-slot=3 "); r=$(line_of "remove-policy")
[[ -n $a && -n $w && -n $r && $a -lt $w && $w -lt $r ]] && ok "passphrase first, then the TPM slot, then the TPM policy" || bad "order: add $a, wipe $w, remove-policy $r"
grep -qF "$NEW" "$STUB_LOG" && bad "the passphrase reached a command line" || ok "the passphrase never reaches a command line or log"
[[ ! -e $T/var/lib/systemd/pcrlock.json && ! -e $T/var/lib/monarchy-encryption && -z $(ls "$T/var/lib/pcrlock.d" 2>/dev/null) ]] \
  && ok "the policy, its recovery PIN and the boot file descriptions are gone" || bad "policy left: $(find "$T/var" -type f)"
[[ -z $(ls "$T/etc/boot/hooks/post.d" 2>/dev/null) && ! -e $T/etc/systemd/system/multi-user.target.wants/monarchy-encryption-boot.service ]] \
  && ok "our Limine hooks and the boot service are unlinked" || bad "hooks left"
me status --json
[[ $(js '[.disk.tpm_enrolled, .disk.passphrase, .tpm_policy.exists] | map(tostring) | join(" ")') == "false true false" ]] \
  && ok "status: no TPM, a passphrase, no policy" || bad "status: $OUT"
remember; me_in "" reassert
[[ $RC -eq 0 && $ERR == *"setup hasn't run"* && $(snap) == "$BEFORE" ]] && ok "updates leave it alone (reassert has nothing to do)" || bad "reassert: $ERR"
me_in "" release; [[ $RC -eq 0 && $ERR == *"nothing to release"* ]] && ok "release again: nothing to do" || bad "again: $ERR"
me_in "$NEW" setup --json; restart
[[ $RC -eq 0 && $(slots) == "2 recovery,3 tpm2" ]] && ok "setup takes it back (setup, then a restart)" || bad "setup again: rc $RC: $ERR $(slots)"

echo "[the firmware changed since setup: the TPM no longer opens the disk]"
setup_done; sed -i 's/ tpm2 -$/ tpm2 stale/' "$T/state/keyslots"; remember
me_in "$NEW" release
[[ $RC -eq 1 && $ERR == *"recovery key"* ]] && unchanged && ok "without the recovery key: asks for it, nothing changed" || bad "rc $RC: $ERR"
me_in "$NEW"$'\n'"$KEY" release
[[ $RC -eq 0 && $(slots) == "0 password,2 recovery" ]] && opens "$NEW" && ok "with the recovery key as the second line: released" || bad "rc $RC: $ERR $(slots)"
check "the recovery key unlocked the change" called "cryptsetup luksAddKey --key-file=/dev/fd/"

echo "[the disk still has a passphrase]"
setup_done; echo "0 password $DISK_PASSPHRASE" >> "$T/state/keyslots"; : > "$STUB_LOG"   # one added back by hand
me_in "" release
[[ $RC -eq 0 && $ERR == *"keeping it"* && $(slots) == "0 password,2 recovery" ]] && ! called "luksAddKey" && ok "no new passphrase asked; the TPM slot goes" || bad "rc $RC: $ERR $(slots)"

echo "[before the restart after setup (the one-time unlock, no policy yet)]"
sandbox; me_in "$DISK_PASSPHRASE" setup >/dev/null; me_in "" release
[[ $RC -eq 0 && $(slots) == "0 password,2 recovery" ]] && ok "the one-time unlock removed, the passphrase kept" || bad "rc $RC: $ERR $(slots)"
[[ ! -e $T/etc/systemd/system/multi-user.target.wants/monarchy-encryption-boot.service ]] && ok "nothing left to run at the next start" || bad "boot service still linked"

echo "[refusals]"
setup_done; remember; me_in "" release
[[ $RC -eq 1 && $ERR == *"new disk passphrase"* ]] && unchanged && ok "no new passphrase: says how to give one, nothing changed" || bad "rc $RC: $ERR"
me_in "$NEW" release --bogus; [[ $RC -eq 1 && $ERR == Usage:* ]] && ok "unknown options: usage" || bad "--bogus"
result
