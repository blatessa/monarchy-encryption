#!/bin/bash
# setup and the restart after it: setup leaves a one-time TPM unlock and the recovery key; at the restart,
# finish binds the TPM to Secure Boot (PCR 7), removes the passphrase and the one-time unlock, with nothing typed.
# The one-time unlock goes whatever happens; refusals leave the keyslots alone.
source "$(dirname "$0")/lib.sh"

slots() { awk '{print $1, $2}' "$T/state/keyslots" | sort -n | paste -sd, -; }        # "0 password,1 recovery"
restarted() { efivar SecureBoot 1; }   # the firmware after the restart: Secure Boot on, with the keys setup enrolled
line_of() { grep -n -F -- "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }
link() { echo "$T/etc/systemd/system/multi-user.target.wants/monarchy-encryption-finish.service"; }

echo "[setup]"
sandbox
me_in "$DISK_PASSPHRASE" setup --json
key=$(js .recovery_key)
[[ $RC -eq 0 && $(js '[.done, .passphrase] | @tsv') == $'false\tkept' && $key =~ ^[a-z]{8}(-[a-z]{8}){7}$ ]] \
  && ok "Secure Boot and a recovery key; not done until the restart" || { bad "rc $RC: $OUT"; sed 's/^/      /' <<<"$ERR"; }
[[ $(slots) == "0 password,1 tpm2,2 recovery" ]] && ok "the passphrase kept; the one-time unlock and the recovery key added" || bad "slots: $(slots)"
check "the one-time unlock is bound to nothing" called "--tpm2-device=auto --tpm2-pcrs= /dev/vda2"
called "--tpm2-pcrs=7" && bad "bound to PCR 7 before Secure Boot is on" || ok "nothing bound to PCR 7 yet (it would mean 'Secure Boot off')"
check "the one-time unlock is proven through the token the initramfs uses" called "cryptsetup open --test-passphrase --token-only --token-id=0 /dev/vda2"
[[ $(readlink "$(link)") == /usr/lib/systemd/system/monarchy-encryption-finish.service ]] && ok "finish runs at the next start" || bad "link: $(readlink "$(link)")"
s=$(line_of "sbctl enroll-keys"); o=$(line_of "--tpm2-pcrs= "); r=$(line_of "--recovery-key")
[[ -n $s && -n $o && -n $r && $s -lt $o && $o -lt $r ]] && ok "keys, then the one-time unlock, then the recovery key: the output that carries it is the final one" || bad "order: keys $s, one-time $o, recovery $r"
me_in "$DISK_PASSPHRASE" setup
[[ $RC -eq 0 && $ERR == *"restart the laptop: it finishes"* && -z $OUT && $(slots) == "0 password,1 tpm2,2 recovery" ]] \
  && ok "again before the restart: says to restart, no new key or unlock" || bad "rerun: rc $RC: $OUT $ERR"
me_in "" setup --json
[[ $RC -eq 0 && $(js .recovery_key) == null ]] && ok "and needs no passphrase to say so" || bad "no stdin: rc $RC: $ERR"

echo "[the restart: finish, with nobody to answer]"
restarted; : > "$STUB_LOG"
me_in "" finish
[[ $RC -eq 0 && $ERR == *"setup finished"* && -z $OUT ]] && ok "finished with nothing typed" || bad "rc $RC: $OUT $ERR"
check "bound to PCR 7 (Secure Boot state), unlocked by the one-time unlock" called "--unlock-tpm2-device=auto --tpm2-device=auto --tpm2-pcrs=7 /dev/vda2"
check "proven through the token the initramfs uses" called "cryptsetup open --test-passphrase --token-only --token-id="
[[ $(slots) == "2 recovery,3 tpm2" ]] && ok "the TPM and the recovery key are left; the passphrase and the one-time unlock are gone" || bad "slots: $(slots)"
t=$(line_of "--tpm2-pcrs=7"); p=$(line_of "--wipe-slot=0 "); o=$(line_of "--wipe-slot=1 ")
[[ -n $t && -n $p && -n $o && $t -lt $p && $p -lt $o ]] && ok "the TPM proven before the passphrase goes; the one-time unlock last" || bad "order: tpm $t, passphrase $p, one-time $o"
[[ ! -e $(link) ]] && ok "finish won't run again" || bad "still linked"
called "--recovery-key" && bad "a recovery key made where nobody sees it" || ok "no recovery key made (nobody to hand it to)"
me status --json
[[ $(js .protected) == true && $(js '.disk | [.tpm_unlock, .one_time_unlock, .recovery_key, .passphrase] | map(tostring) | join(" ")') == "true false true false" ]] \
  && ok "status: protected" || bad "status: $OUT"
: > "$STUB_LOG"; me_in "" finish
[[ $RC -eq 0 && $ERR == *"nothing to finish"* ]] && ! called "systemd-cryptenroll" && ok "finish again: nothing to do" || bad "again: rc $RC: $ERR"

echo "[done: setup again changes nothing]"
: > "$STUB_LOG"; before=$(cat "$T/state/keyslots"); BEFORE=$(snap)
me_in "" setup --json
[[ $RC -eq 0 && $(js '[.done, .passphrase] | @tsv') == $'true\tnone' && $(cat "$T/state/keyslots") == "$before" && $(snap) == "$BEFORE" ]] \
  && ok "no input needed, nothing changed" || bad "rc $RC: $OUT $ERR"
called "systemd-cryptenroll" && bad "keyslots touched" || ok "no keyslot touched"
me_in "" recovery-key --json
[[ $RC -eq 0 && $(js .previous_key) == removed ]] && ok "the recovery key can now be replaced with no passphrase at all (the TPM)" || bad "recovery-key: rc $RC: $ERR"

echo "[the restart came up without Secure Boot]"
sandbox; me_in "$DISK_PASSPHRASE" setup --json; key=$(js .recovery_key); : > "$STUB_LOG"
me_in "" finish
[[ $RC -eq 0 && $ERR == *"Turn Secure Boot on"* && $(slots) == "0 password,2 recovery" && ! -e $(link) ]] \
  && ok "the one-time unlock removed: the disk asks for its passphrase again; says what to do" || bad "rc $RC: $ERR $(slots)"
called "--tpm2-device" && bad "the TPM enrolled without Secure Boot" || ok "nothing enrolled"
restarted
me_in "$DISK_PASSPHRASE" setup
[[ $RC -eq 0 && $ERR == *"run setup again with the recovery key"* && $(slots) == "0 password,1 tpm2,2 recovery" ]] \
  && ok "Secure Boot turned on later: setup with the passphrase enrolls the TPM and keeps the passphrase" || bad "rc $RC: $OUT $ERR $(slots)"
me_in "wrong" setup
[[ $RC -eq 1 && $ERR == *"doesn't open the disk"* && $(slots) == "0 password,1 tpm2,2 recovery" ]] \
  && ok "a wrong key is refused although the TPM opens the disk (tokens are left out of the check)" || bad "wrong with TPM: rc $RC: $ERR"
me_in "$key" setup --json
[[ $RC -eq 0 && $(js '[.done, .passphrase] | @tsv') == $'true\tremoved' && $(slots) == "1 tpm2,2 recovery" ]] \
  && ok "and with the recovery key, the passphrase is removed" || bad "rc $RC: $OUT $ERR $(slots)"

echo "[finish fails: the TPM doesn't open the disk with PCR 7]"
sandbox; me_in "$DISK_PASSPHRASE" setup >/dev/null; restarted
STUB_TPM_UNLOCK_FAIL=1 me_in "" finish
[[ $RC -eq 1 && $(slots) == "0 password,2 recovery" && ! -e $(link) ]] \
  && ok "refused; the passphrase kept, the one-time unlock removed anyway" || bad "rc $RC: $ERR $(slots)"

echo "[finish with no recovery key (removed by hand before the restart)]"
sandbox; me_in "$DISK_PASSPHRASE" setup >/dev/null; sed -i '/ recovery /d' "$T/state/keyslots"; restarted
me_in "" finish
[[ $RC -eq 0 && $ERR == *"run recovery-key"* && $(slots) == "0 password,2 tpm2" ]] \
  && ok "the TPM enrolled, the passphrase kept: it's the only other way in" || bad "rc $RC: $ERR $(slots)"

echo "[setup by hand after the restart, before finish ran]"
sandbox; me_in "$DISK_PASSPHRASE" setup >/dev/null; restarted
me_in "" setup --json
[[ $RC -eq 0 && $(js '[.done, .passphrase] | @tsv') == $'true\tremoved' && $(slots) == "2 recovery,3 tpm2" && ! -e $(link) ]] \
  && ok "the same as finish, with nothing typed" || bad "rc $RC: $OUT $ERR $(slots)"

echo "[refusals change nothing]"
sandbox; BEFORE=$(snap)
me_in "wrong" setup
[[ $RC -eq 1 && $ERR == *"doesn't open the disk"* && $(snap) == "$BEFORE" && $(slots) == "0 password" ]] \
  && ok "a wrong passphrase: refused before anything is changed" || bad "wrong: rc $RC: $ERR"
called "limine-update" && bad "boot files rebuilt anyway" || ok "the boot files weren't touched"
me_in "" setup
[[ $RC -eq 1 && $ERR == *"give it on stdin"* && $(snap) == "$BEFORE" ]] && ok "no passphrase: says how to give it, nothing changed" || bad "no stdin: rc $RC: $ERR"
rm "$T/tpmrm0"
me_in "$DISK_PASSPHRASE" setup
[[ $RC -eq 1 && $ERR == *"no TPM 2.0"* && $(snap) == "$BEFORE" && $(slots) == "0 password" ]] \
  && ok "no TPM: refused up front with what to turn on, nothing changed" || bad "no TPM: rc $RC: $ERR"
sandbox; me_in "$DISK_PASSPHRASE" setup >/dev/null; me_in "" finish >/dev/null
before=$(cat "$T/state/keyslots"); STUB_TPM_UNLOCK_FAIL=1 me_in "$DISK_PASSPHRASE" setup
[[ $RC -eq 1 && $ERR == *"removed again"* && $(slots) == "0 password,2 recovery" ]] \
  && ok "a one-time unlock that doesn't open the disk: removed again" || bad "one-time fails: rc $RC: $ERR $(slots)"

echo "[the firmware or its keys changed since (PCR 7 differs)]"
sandbox; me_in "$DISK_PASSPHRASE" setup --json; key=$(js .recovery_key); restarted; me_in "" finish
sed -i 's/ tpm2 -$/ tpm2 stale/' "$T/state/keyslots"; : > "$STUB_LOG"
me_in "" setup
[[ $RC -eq 1 && $ERR == *"give it on stdin"* ]] && ok "the TPM no longer opens it: setup asks for the recovery key" || bad "stale, no key: rc $RC: $ERR"
me_in "$key" setup --json
[[ $RC -eq 0 && $(js .done) == true && $(slots) == "0 tpm2,2 recovery" && $ERR == *"enrolled afresh"* ]] \
  && ok "enrolled afresh with the recovery key, the stale slot removed" || bad "stale: rc $RC: $OUT $ERR $(slots)"
t=$(line_of "--tpm2-device"); w=$(line_of "--wipe-slot=3 ")
[[ -n $t && -n $w && $t -lt $w ]] && ok "the new enrollment comes before the old one is removed" || bad "order: enroll $t, wipe $w"

echo "[Secure Boot already on, no recovery key yet]"
sandbox; me_in "$DISK_PASSPHRASE" setup >/dev/null; echo "0 password $DISK_PASSPHRASE" > "$T/state/keyslots"; restarted
me_in "$DISK_PASSPHRASE" setup --json
[[ $RC -eq 0 && $(js '[.done, .passphrase] | @tsv') == $'true\tkept' && $(js .recovery_key) =~ ^[a-z] ]] \
  && ok "TPM and a new recovery key in one run; the passphrase kept until the key comes back" || bad "rc $RC: $OUT $ERR"
result
