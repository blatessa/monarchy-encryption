#!/bin/bash
# setup and the restart after it: setup leaves a one-time TPM unlock and the recovery key; at the restart, the boot
# service makes the TPM policy from that start, binds the TPM to it, removes the passphrase and the one-time unlock,
# with nothing typed. The one-time unlock goes whatever happens; refusals leave the keyslots alone.
source "$(dirname "$0")/lib.sh"

slots() { awk '{print $1, $2}' "$T/state/keyslots" | sort -n | paste -sd, -; }        # "0 password,1 recovery"
line_of() { grep -n -F -- "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }
link() { echo "$T/etc/systemd/system/multi-user.target.wants/monarchy-encryption-boot.service"; }
pcrlock_bound() { ls "$T"/state/tpm2-pcrlock-* >/dev/null 2>&1; }

echo "[setup]"
sandbox
me_in "$DISK_PASSPHRASE" setup --json
key=$(js .recovery_key)
[[ $RC -eq 0 && $(js '[.done, .passphrase] | @tsv') == $'false\tkept' && $key =~ ^[a-z]{8}(-[a-z]{8}){7}$ ]] \
  && ok "the boot files and a recovery key; not done until the restart" || { bad "rc $RC: $OUT"; sed 's/^/      /' <<<"$ERR"; }
[[ $(slots) == "0 password,1 tpm2,2 recovery" ]] && ok "the passphrase kept; the one-time unlock and the recovery key added" || bad "slots: $(slots)"
check "the one-time unlock is bound to nothing, not even pcrlock.json" called "--tpm2-device=auto --tpm2-pcrs= --tpm2-pcrlock= /dev/vda2"
called "make-policy" && bad "a policy made from the start before the boot files changed" || ok "no policy yet (it comes from the restart's measurements)"
check "the one-time unlock is proven through the token the initramfs uses" called "cryptsetup open --test-passphrase --token-only --token-id=0 /dev/vda2"
[[ $(readlink "$(link)") == /usr/lib/systemd/system/monarchy-encryption-boot.service ]] && ok "the boot service runs at every start" || bad "link: $(readlink "$(link)")"
check "the policy's recovery PIN is root-only" test "$(stat -c %a "$T/var/lib/monarchy-encryption/pin")" = 600
p=$(line_of "predict"); u=$(line_of "limine-update"); o=$(line_of "--tpm2-pcrs= "); r=$(line_of "--recovery-key")
[[ -n $p && -n $u && -n $o && -n $r && $p -lt $u && $u -lt $o && $o -lt $r ]] \
  && ok "checked the firmware's measurements first; the boot files, the one-time unlock, then the recovery key last" || bad "order: predict $p, rebuild $u, one-time $o, recovery $r"
me_in "$DISK_PASSPHRASE" setup
[[ $RC -eq 0 && $ERR == *"restart the laptop: it finishes"* && -z $OUT && $(slots) == "0 password,1 tpm2,2 recovery" ]] \
  && ok "again before the restart: says to restart, no new key or unlock" || bad "rerun: rc $RC: $OUT $ERR"
me_in "" setup --json
[[ $RC -eq 0 && $(js .recovery_key) == null ]] && ok "and needs no passphrase to say so" || bad "no stdin: rc $RC: $ERR"

echo "[the restart: the boot service, with nobody to answer]"
: > "$STUB_LOG"; restart
[[ $RC -eq 0 && $ERR == *"setup finished"* && -z $OUT ]] && ok "finished with nothing typed" || bad "rc $RC: $OUT $ERR"
check "the policy made from this start, over PCR 4 and 11, strict, with the recovery PIN" called "make-policy --no-pager --policy=$T/var/lib/systemd/pcrlock.json --pcr=4 --pcr=11 --strict=yes --recovery-pin=query"
check "bound to the policy, unlocked by the one-time unlock" called "--unlock-tpm2-device=auto --tpm2-device=auto --tpm2-pcrlock=$T/var/lib/systemd/pcrlock.json /dev/vda2"
pcrlock_bound && ok "the TPM slot is a pcrlock one" || bad "not bound to the policy"
check "proven through the token the initramfs uses" called "cryptsetup open --test-passphrase --token-only --token-id="
[[ $(slots) == "2 recovery,3 tpm2" ]] && ok "the TPM and the recovery key are left; the passphrase and the one-time unlock are gone" || bad "slots: $(slots)"
m=$(line_of "make-policy"); t=$(line_of "--tpm2-pcrlock=$T"); p=$(line_of "--wipe-slot=0 "); o=$(line_of "--wipe-slot=1 ")
[[ -n $m && -n $t && -n $p && -n $o && $m -lt $t && $t -lt $p && $p -lt $o ]] && ok "the policy, then the TPM proven before the passphrase goes; the one-time unlock last" || bad "order: policy $m, tpm $t, passphrase $p, one-time $o"
called "--recovery-key" && bad "a recovery key made where nobody sees it" || ok "no recovery key made (nobody to hand it to)"
grep -qF "$(cat "$T/var/lib/monarchy-encryption/pin")" "$STUB_LOG" && bad "the PIN reached a command line" || ok "the PIN never reaches a command line"
me status --json
[[ $(js .protected) == true && $(js '.disk | [.tpm_unlock, .one_time_unlock, .recovery_key, .passphrase] | map(tostring) | join(" ")') == "true false true false" ]] \
  && ok "status: protected" || bad "status: $OUT"
: > "$STUB_LOG"; restart
[[ $RC -eq 0 && $ERR != *"setup finished"* ]] && called "make-policy" && ! called "systemd-cryptenroll" && ok "every later start: the policy follows what started, no keyslot touched" || bad "again: rc $RC: $ERR"

echo "[done: setup again changes nothing]"
: > "$STUB_LOG"; before=$(cat "$T/state/keyslots"); BEFORE=$(snap)
me_in "" setup --json
[[ $RC -eq 0 && $(js '[.done, .passphrase] | @tsv') == $'true\tnone' && $(cat "$T/state/keyslots") == "$before" && $(snap) == "$BEFORE" ]] \
  && ok "no input needed, nothing changed" || bad "rc $RC: $OUT $ERR"
called "systemd-cryptenroll" && bad "keyslots touched" || ok "no keyslot touched"
me_in "" recovery-key --json
[[ $RC -eq 0 && $(js .previous_key) == removed ]] && ok "the recovery key can now be replaced with no passphrase at all (the TPM)" || bad "recovery-key: rc $RC: $ERR"

echo "[the restart's measurements can't be predicted]"
sandbox; me_in "$DISK_PASSPHRASE" setup --json; key=$(js .recovery_key); : > "$STUB_LOG"
STUB_PCRLOCK_UNPREDICTABLE=1 restart
[[ $RC -eq 0 && $ERR == *"can't finish without a TPM policy"* && $(slots) == "0 password,2 recovery" ]] \
  && ok "the one-time unlock removed: the disk asks for its passphrase again; says what to do" || bad "rc $RC: $ERR $(slots)"
called "--tpm2-device" && bad "the TPM enrolled without a policy" || ok "nothing enrolled"
restart
me_in "$DISK_PASSPHRASE" setup
[[ $RC -eq 0 && $ERR == *"run setup again with the recovery key"* && $(slots) == "0 password,1 tpm2,2 recovery" ]] \
  && ok "once a start can be predicted, setup with the passphrase enrolls the TPM and keeps the passphrase" || bad "rc $RC: $OUT $ERR $(slots)"
me_in "wrong" setup
[[ $RC -eq 1 && $ERR == *"doesn't open the disk"* && $(slots) == "0 password,1 tpm2,2 recovery" ]] \
  && ok "a wrong key is refused although the TPM opens the disk (tokens are left out of the check)" || bad "wrong with TPM: rc $RC: $ERR"
me_in "$key" setup --json
[[ $RC -eq 0 && $(js '[.done, .passphrase] | @tsv') == $'true\tremoved' && $(slots) == "1 tpm2,2 recovery" ]] \
  && ok "and with the recovery key, the passphrase is removed" || bad "rc $RC: $OUT $ERR $(slots)"

echo "[the boot service fails: the TPM doesn't open the disk with the policy]"
sandbox; me_in "$DISK_PASSPHRASE" setup >/dev/null
STUB_TPM_UNLOCK_FAIL=1 restart
[[ $RC -eq 1 && $(slots) == "0 password,2 recovery" ]] \
  && ok "refused; the passphrase kept, the one-time unlock removed anyway" || bad "rc $RC: $ERR $(slots)"

echo "[no recovery key (removed by hand before the restart)]"
sandbox; me_in "$DISK_PASSPHRASE" setup >/dev/null; sed -i '/ recovery /d' "$T/state/keyslots"
restart
[[ $RC -eq 0 && $ERR == *"run recovery-key"* && $(slots) == "0 password,2 tpm2" ]] \
  && ok "the TPM enrolled, the passphrase kept: it's the only other way in" || bad "rc $RC: $ERR $(slots)"

echo "[refusals change nothing]"
sandbox; BEFORE=$(snap)
me_in "wrong" setup
[[ $RC -eq 1 && $ERR == *"doesn't open the disk"* && $(snap) == "$BEFORE" && $(slots) == "0 password" ]] \
  && ok "a wrong passphrase: refused before anything is changed" || bad "wrong: rc $RC: $ERR"
called "limine-update" && bad "boot files rebuilt anyway" || ok "the boot files weren't touched"
me_in "" setup
[[ $RC -eq 1 && $ERR == *"give it on stdin"* && $(snap) == "$BEFORE" ]] && ok "no passphrase: says how to give it, nothing changed" || bad "no stdin: rc $RC: $ERR"
STUB_PCRLOCK_UNPREDICTABLE=1 me_in "$DISK_PASSPHRASE" setup
[[ $RC -eq 1 && $ERR == *"record of this start doesn't match"*"restart it"* && $(snap) == "$BEFORE" && $(slots) == "0 password" ]] \
  && ok "the firmware's measurements can't be predicted: refused up front, nothing changed" || bad "unpredictable: rc $RC: $ERR"
STUB_PCRLOCK_UNSUPPORTED=1 me_in "$DISK_PASSPHRASE" setup
[[ $RC -eq 1 && $ERR == *"can't hold the boot policy"* && $(snap) == "$BEFORE" ]] && ok "a TPM without PolicyAuthorizeNV: refused, nothing changed" || bad "unsupported: rc $RC: $ERR"
rm "$T/tpmrm0"
me_in "$DISK_PASSPHRASE" setup
[[ $RC -eq 1 && $ERR == *"no TPM 2.0"* && $(snap) == "$BEFORE" && $(slots) == "0 password" ]] \
  && ok "no TPM: refused up front with what to turn on, nothing changed" || bad "no TPM: rc $RC: $ERR"
sandbox; rm -rf "$T/efivars"; BEFORE=$(snap); me_in "$DISK_PASSPHRASE" setup
[[ $RC -eq 1 && $ERR == *"UEFI"* && $(snap) == "$BEFORE" ]] && ok "not started in UEFI mode: refused, nothing changed" || bad "no UEFI: rc $RC: $ERR"
sandbox; STUB_TPM_UNLOCK_FAIL=1 me_in "$DISK_PASSPHRASE" setup
[[ $RC -eq 1 && $ERR == *"removed again"* && $(slots) == "0 password" ]] \
  && ok "a one-time unlock that doesn't open the disk: removed again" || bad "one-time fails: rc $RC: $ERR $(slots)"

echo "[the TPM no longer opens the disk]"
sandbox; me_in "$DISK_PASSPHRASE" setup --json; key=$(js .recovery_key); restart
sed -i 's/ tpm2 -$/ tpm2 stale/' "$T/state/keyslots"; restart; : > "$STUB_LOG"
me_in "" setup
[[ $RC -eq 1 && $ERR == *"give it on stdin"* ]] && ok "setup asks for the recovery key" || bad "stale, no key: rc $RC: $ERR"
me_in "$key" setup --json
[[ $RC -eq 0 && $(js .done) == true && $(slots) == "0 tpm2,2 recovery" && $ERR == *"enrolled afresh"* ]] \
  && ok "enrolled afresh with the recovery key, the stale slot removed" || bad "stale: rc $RC: $OUT $ERR $(slots)"
t=$(line_of "--tpm2-device"); w=$(line_of "--wipe-slot=3 ")
[[ -n $t && -n $w && $t -lt $w ]] && ok "the new enrollment comes before the old one is removed" || bad "order: enroll $t, wipe $w"
r=$(line_of "remove-policy"); m=$(grep -n "make-policy" "$STUB_LOG" | tail -1 | cut -d: -f1)
[[ -n $r && -n $m && $r -lt $m && $m -lt $t ]] && ok "the policy written into the TPM afresh first (a cleared TPM has none)" || bad "order: remove $r, make $m, enroll $t"
check "the new policy allows the files that started" grep -qx "uki $(sha256sum < "$T/boot/EFI/Linux/omarchy_linux-omarchy.efi" | cut -d' ' -f1)" "$T/state/policy-covers"
result
