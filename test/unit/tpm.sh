#!/bin/bash
# setup's two runs: the recovery key before the restart; after it, TPM unlock bound to Secure Boot (PCR 7) and the
# passphrase removed only when the TPM and the recovery key each open the disk. Refusals leave the keyslots alone.
source "$(dirname "$0")/lib.sh"

slots() { awk '{print $1, $2}' "$T/state/keyslots" | sort -n | paste -sd, -; }        # "0 password,1 recovery"
restarted() { efivar SecureBoot 1; }   # the firmware after the restart: Secure Boot on, with the keys setup enrolled
line_of() { grep -n -F -- "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }

echo "[the first run]"
sandbox
me_in "$DISK_PASSPHRASE" setup --json
key=$(js .recovery_key)
[[ $RC -eq 0 && $(js '[.done, .passphrase] | @tsv') == $'false\tkept' && $key =~ ^[a-z]{8}(-[a-z]{8}){7}$ ]] \
  && ok "Secure Boot and a recovery key; not done until the restart" || { bad "rc $RC: $OUT"; sed 's/^/      /' <<<"$ERR"; }
[[ $(slots) == "0 password,1 recovery" ]] && ok "the passphrase is kept, the recovery key added" || bad "slots: $(slots)"
called "--tpm2-device" && bad "the TPM was enrolled before Secure Boot is on" || ok "the TPM waits for the restart (PCR 7 would mean 'Secure Boot off')"
r=$(line_of "--recovery-key"); s=$(line_of "sbctl enroll-keys")
[[ -n $r && -n $s && $s -lt $r ]] && ok "the recovery key is made last, so the output that carries it is the final one" || bad "order: keys $s, recovery $r"
me_in "$DISK_PASSPHRASE" setup
[[ $RC -eq 0 && $ERR == *"restart the laptop, then run setup again"* && -z $OUT ]] && ok "again before the restart: says to restart, no new key" || bad "rerun: rc $RC: $OUT $ERR"
me_in "" setup --json
[[ $RC -eq 0 && $(js .recovery_key) == null ]] && ok "and needs no passphrase to say so" || bad "no stdin: rc $RC: $ERR"

echo "[after the restart, with the passphrase]"
restarted; : > "$STUB_LOG"
me_in "$DISK_PASSPHRASE" setup
[[ $RC -eq 0 && $ERR == *"done"* && $ERR == *"run setup again with the recovery key"* && -z $OUT ]] \
  && ok "the TPM unlocks the disk; the passphrase is kept, with how to remove it" || bad "rc $RC: $OUT $ERR"
check "bound to PCR 7 (Secure Boot state)" called "--tpm2-device=auto --tpm2-pcrs=7 /dev/vda2"
check "proven through the token the initramfs uses" called "cryptsetup open --test-passphrase --token-only --token-type systemd-tpm2 /dev/vda2"
[[ $(slots) == "0 password,1 recovery,2 tpm2" ]] && ok "a TPM slot added, nothing removed" || bad "slots: $(slots)"

me_in "wrong" setup
[[ $RC -eq 1 && $ERR == *"doesn't open the disk"* && $(slots) == "0 password,1 recovery,2 tpm2" ]] \
  && ok "a wrong key is refused although the TPM opens the disk (tokens are left out of the check)" || bad "wrong with TPM: rc $RC: $ERR"

echo "[again, with the recovery key]"
: > "$STUB_LOG"
me_in "$key" setup --json
[[ $RC -eq 0 && $(js '[.done, .passphrase, .recovery_key] | map(tostring) | @tsv') == $'true\tremoved\tnull' ]] \
  && ok "the passphrase is removed" || bad "rc $RC: $OUT $ERR"
[[ $(slots) == "1 recovery,2 tpm2" ]] && ok "the TPM and the recovery key are left" || bad "slots: $(slots)"
called "--tpm2-device" && bad "the TPM enrolled twice" || ok "the TPM isn't enrolled again"
t=$(line_of "--token-only"); w=$(line_of "--wipe-slot=0 "); a=$(grep -n -F -- "--token-only" "$STUB_LOG" | tail -1 | cut -d: -f1)
[[ -n $t && -n $w && $t -lt $w && $a -gt $w ]] && ok "the TPM is proven before the passphrase goes, and again after" || bad "order: tpm $t, wipe $w, after $a"
me status --json
[[ $(js '.disk | [.tpm_unlock, .recovery_key, .passphrase] | map(tostring) | join(" ")') == "true true false" ]] \
  && ok "status: TPM and recovery key, no passphrase" || bad "status: $OUT"

echo "[done: again changes nothing]"
: > "$STUB_LOG"; before=$(cat "$T/state/keyslots"); BEFORE=$(snap)
me_in "" setup --json
[[ $RC -eq 0 && $(js '[.done, .passphrase] | @tsv') == $'true\tnone' && $(cat "$T/state/keyslots") == "$before" && $(snap) == "$BEFORE" ]] \
  && ok "no input needed, nothing changed" || bad "rc $RC: $OUT $ERR"
called "systemd-cryptenroll" && bad "keyslots touched" || ok "no keyslot touched"
me_in "" recovery-key --json
[[ $RC -eq 0 && $(js .previous_key) == removed ]] && ok "the recovery key can now be replaced with no passphrase at all (the TPM)" || bad "recovery-key: rc $RC: $ERR"

echo "[refusals change nothing]"
sandbox; BEFORE=$(snap)
me_in "wrong" setup
[[ $RC -eq 1 && $ERR == *"doesn't open the disk"* && $(snap) == "$BEFORE" && $(slots) == "0 password" ]] \
  && ok "a wrong passphrase: refused before anything is changed" || bad "wrong: rc $RC: $ERR"
called "limine-update" && bad "boot files rebuilt anyway" || ok "the boot files weren't touched"
me_in "" setup
[[ $RC -eq 1 && $ERR == *"give it on stdin"* && $(snap) == "$BEFORE" ]] && ok "no passphrase: says how to give it, nothing changed" || bad "no stdin: rc $RC: $ERR"

sandbox; me_in "$DISK_PASSPHRASE" setup --json; key=$(js .recovery_key); restarted; rm "$T/tpmrm0"
me_in "$key" setup
[[ $RC -eq 1 && $ERR == *"no TPM 2.0"* && $(slots) == "0 password,1 recovery" ]] && ok "no TPM: refused with what to turn on, passphrase kept" || bad "no TPM: rc $RC: $ERR"
: > "$T/tpmrm0"
STUB_TPM_UNLOCK_FAIL=1 me_in "$key" setup
[[ $RC -eq 1 && $ERR == *"removed again"* && $(slots) == "0 password,1 recovery" ]] \
  && ok "a TPM that doesn't open the disk: its slot removed again, passphrase kept even with the recovery key given" || bad "tpm fails: rc $RC: $ERR $(slots)"

echo "[the firmware or its keys changed since (PCR 7 differs)]"
sandbox; me_in "$DISK_PASSPHRASE" setup --json; key=$(js .recovery_key); restarted; me_in "$key" setup >/dev/null
sed -i 's/ tpm2 -$/ tpm2 stale/' "$T/state/keyslots"; : > "$STUB_LOG"
me_in "" setup
[[ $RC -eq 1 && $ERR == *"give it on stdin"* ]] && ok "the TPM no longer opens it: setup asks for the recovery key" || bad "stale, no key: rc $RC: $ERR"
me_in "$key" setup --json
[[ $RC -eq 0 && $(js .done) == true && $(slots) == "0 tpm2,1 recovery" && $ERR == *"enrolled afresh"* ]] \
  && ok "enrolled afresh with the recovery key, the stale slot removed" || bad "stale: rc $RC: $OUT $ERR $(slots)"
t=$(line_of "--tpm2-device"); w=$(line_of "--wipe-slot=2 ")
[[ -n $t && -n $w && $t -lt $w ]] && ok "the new enrollment comes before the old one is removed" || bad "order: enroll $t, wipe $w"

echo "[Secure Boot already on, no recovery key yet]"
sandbox; me_in "$DISK_PASSPHRASE" setup >/dev/null; rm "$T/state/keyslots"; echo "0 password $DISK_PASSPHRASE" > "$T/state/keyslots"; restarted
me_in "$DISK_PASSPHRASE" setup --json
[[ $RC -eq 0 && $(js '[.done, .passphrase] | @tsv') == $'true\tkept' && $(js .recovery_key) =~ ^[a-z] ]] \
  && ok "TPM and a new recovery key in one run; the passphrase kept until the key comes back" || bad "rc $RC: $OUT $ERR"
result
