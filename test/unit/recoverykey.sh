#!/bin/bash
# recovery-key: the key is created or replaced, proven to open the disk before the old one goes, handed over once on
# stdout (or in JSON), and never written anywhere else. Every refusal leaves the disk's keyslots as they were.
source "$(dirname "$0")/lib.sh"

RE='^[a-z]{8}(-[a-z]{8}){7}$'
slots() { awk '{print $1, $2}' "$T/state/keyslots" | paste -sd, -; }        # "0 password,1 recovery"
opens() { awk -v k="$1" '$3 == k {f=1} END {exit !f}' "$T/state/keyslots"; }  # does this key open the disk?
nowhere_else() {  # the key is in no file but the disk's (stub) header: not under /etc or the ESP, not in the call log
  ! grep -rqF -- "$1" "$T/etc" "$T/boot" "$T/home" "$STUB_LOG"
}

echo "[the first recovery key, the passphrase on stdin]"
sandbox
me_in "$DISK_PASSPHRASE" recovery-key
[[ $RC -eq 0 ]] && ok "recovery-key succeeds" || { bad "rc $RC"; sed 's/^/      /' <<<"$ERR"; }
[[ $OUT =~ $RE ]] && ok "stdout is the key and nothing else" || bad "stdout: $OUT"
key1=$OUT
[[ $(slots) == "0 password,1 recovery" ]] && ok "a recovery slot next to the passphrase" || bad "slots: $(slots)"
check "the key opens the disk" opens "$key1"
[[ $ERR == *"shown only now"* && $ERR == *"disk prompt"* && $ERR != *"previous"* ]] && ok "it says to store it and where it's typed" || bad "stderr: $ERR"
check "the key is written nowhere (files, logs, command lines)" nowhere_else "$key1"
check "nor is the passphrase" nowhere_else "$DISK_PASSPHRASE"
check "systemd-cryptenroll is given the passphrase on a pipe" called "systemd-cryptenroll --unlock-key-file=/dev/stdin --recovery-key /dev/vda2"
check "the new key is tested on its own slot, tokens left out" called "cryptsetup open --test-passphrase --disable-external-tokens --key-file=- --key-slot=1 /dev/vda2"
check "the log says what happened" called "logger -t monarchy-encryption -- recovery key created"

echo "[replacing it, --json]"
: > "$STUB_LOG"
me_in "$DISK_PASSPHRASE" recovery-key --json
key2=$(js .recovery_key)
[[ $RC -eq 0 && $(js '[.schema, .previous_key] | @tsv') == $'1\tremoved' && $key2 =~ $RE && $key2 != "$key1" ]] \
  && ok "a new key, in JSON; the previous one removed" || bad "rc $RC: $OUT $ERR"
[[ $(slots) == "0 password,2 recovery" ]] && ok "one recovery slot, the passphrase kept" || bad "slots: $(slots)"
check "the new key opens the disk" opens "$key2"
opens "$key1" && bad "the old key still opens the disk" || ok "the old key no longer does"
t=$(grep -n -- "--test-passphrase" "$STUB_LOG" | cut -d: -f1); w=$(grep -n -- "--wipe-slot=1 " "$STUB_LOG" | cut -d: -f1)
[[ -n $t && -n $w && $t -lt $w ]] && ok "the new key is proven before the old one is removed" || bad "order: test line $t, wipe line $w"
check "the key is written nowhere" nowhere_else "$key2"

echo "[replacing it with the current recovery key instead of the passphrase]"
me_in "$key2" recovery-key --json
key3=$(js .recovery_key)
[[ $RC -eq 0 && $(js .previous_key) == removed ]] && opens "$key3" && ! opens "$key2" \
  && ok "the recovery key unlocks its own replacement" || bad "rc $RC: $OUT $ERR"

echo "[refusals change nothing]"
before=$(cat "$T/state/keyslots")
me_in "wrong passphrase" recovery-key
[[ $RC -eq 1 && -z $OUT && $ERR == *"doesn't open the disk"* && $(cat "$T/state/keyslots") == "$before" ]] \
  && ok "a wrong passphrase: refused, no key printed, nothing changed" || bad "wrong: rc $RC: $OUT $ERR"
me_in "" recovery-key
[[ $RC -eq 1 && $ERR == *"give it on stdin"* && $(cat "$T/state/keyslots") == "$before" ]] \
  && ok "no passphrase and no terminal: says how to give it, nothing changed" || bad "no stdin: rc $RC: $OUT"
STUB_RECOVERY_KEY_BROKEN=1 me_in "$DISK_PASSPHRASE" recovery-key --json
[[ $RC -eq 1 && -z $OUT && $ERR == *"removed again"* && $(cat "$T/state/keyslots") == "$before" ]] && opens "$key3" \
  && ok "a new key that doesn't open the disk: removed again, the old one kept and still working" || bad "broken: rc $RC: $OUT $ERR"
STUB_KEY_UNREADABLE=1 me_in "$DISK_PASSPHRASE" recovery-key --json
[[ $RC -eq 1 && -z $OUT && $ERR == *"removed again"* && $(cat "$T/state/keyslots") == "$before" ]] && opens "$key3" \
  && ok "a key enrolled but not readable from the output: removed again (nobody would have it)" || bad "unreadable: rc $RC: $OUT $ERR"
me_in "$DISK_PASSPHRASE" recovery-key --bogus
[[ $RC -eq 1 && $ERR == Usage:* ]] && ok "unknown options: usage, exit 1" || bad "--bogus: rc $RC"
STUB_NOT_LUKS=1 me_in "$DISK_PASSPHRASE" recovery-key
[[ $RC -eq 1 && $ERR == *"isn't encrypted"* ]] && ok "a disk that isn't encrypted: refused" || bad "not LUKS: rc $RC: $ERR"

echo "[the old key can't be removed]"
STUB_WIPE_FAIL=1 me_in "$DISK_PASSPHRASE" recovery-key --json
key4=$(js .recovery_key)
[[ $RC -eq 0 && $(js .previous_key) == not_removed && $ERR == *"WARNING"* ]] && opens "$key4" \
  && ok "the new key is still handed over, and the caller is told the old one works" || bad "wipe fail: rc $RC: $OUT $ERR"

echo "[the TPM unlocks it (after #5)]"
sandbox
echo "1 tpm2 -" >> "$T/state/keyslots"
me_in "" recovery-key --json
[[ $RC -eq 0 && $(js .recovery_key) =~ $RE ]] && ok "no passphrase needed" || bad "tpm: rc $RC: $OUT"
check "unlocked with the TPM" called "systemd-cryptenroll --unlock-tpm2-device=auto --recovery-key /dev/vda2"
[[ $(slots) == "0 password,1 tpm2,2 recovery" ]] && ok "the TPM and passphrase slots are kept" || bad "slots: $(slots)"
STUB_TPM_UNLOCK_FAIL=1 me_in "$DISK_PASSPHRASE" recovery-key --json
[[ $RC -eq 0 && $(js .previous_key) == removed ]] && ok "the TPM refuses (firmware changed): the passphrase on stdin is used instead" || bad "tpm fail: rc $RC: $OUT $ERR"
result
