# TPM unlock: the TPM opens the disk at boot, but only while Secure Boot is on with this laptop's keys (PCR 7).
# Sourced. Why it looks like this: docs/dev/architecture.md, "TPM unlock".

TPM_PCRS=7   # Secure Boot state: on/off and the enrolled keys. Survives kernel and Omarchy updates.

tpm_present() { [[ -e $TPM_DEVICE ]]; }
# The disk's TPM tokens: "bound" ones are the TPM unlock (PCR 7); "one-time" ones, bound to nothing, are the unlock
# setup leaves for the restart after it (below). tpm_tokens KIND prints their token ids, tpm_slots KIND their keyslots.
tpm_tokens_json() {
  cryptsetup luksDump --dump-json-metadata "$ROOT_DEVICE" | jq -c --arg k "$1" '[.tokens | to_entries[]
    | select(.value.type == "systemd-tpm2" and ((.value["tpm2-pcrs"] // [] | length > 0) == ($k == "bound")))]'
}
tpm_tokens() { tpm_tokens_json "$1" | jq -r 'map(.key) | join(" ")'; }
tpm_slots() { tpm_tokens_json "$1" | jq -r '[.[].value.keyslots[]] | sort | join(" ")'; }
tpm_enrolled() { [[ -n $(tpm_slots bound) ]]; }
# The TPM opens the disk now, through the same token the initramfs uses (systemd's cryptsetup token plugin).
token_opens() { cryptsetup open --test-passphrase --token-only --token-id="$1" "$ROOT_DEVICE" </dev/null >/dev/null 2>&1; }
tpm_unlocks() { local t; for t in $(tpm_tokens bound); do token_opens "$t" && return 0; done; return 1; }
# PCR 7 means something only once the laptop has started with Secure Boot on and its own keys: enrolling before that
# restart would bind the disk to "Secure Boot off".
secure_boot_active() { [[ $(efi_flag SecureBoot) == true ]] && own_keys_enrolled; }

tpm_check() { # refuses before anything is changed
  tpm_present || die "this laptop has no TPM 2.0 (no $TPM_DEVICE), so it can't unlock its disk by itself. Turn the TPM \
on in the firmware settings (it may be called PTT or fTPM), then run setup again. Nothing was changed."
}

# Enrolls the TPM (unlocked with DISK_SECRET, or by the one-time unlock when no secret was given) unless it already
# opens the disk, and proves it does. A TPM slot that no longer matches (the firmware or its keys changed since) is
# replaced: the new one is enrolled and proven first.
tpm_setup() {
  tpm_unlocks && return 0
  local old s slot=""; old=$(tpm_slots bound)
  if [[ -n ${DISK_SECRET:-} ]]; then
    enroll_with_secret --tpm2-device=auto --tpm2-pcrs="$TPM_PCRS"
  else
    ENROLL_OUT=$(systemd-cryptenroll --unlock-tpm2-device=auto --tpm2-device=auto --tpm2-pcrs="$TPM_PCRS" "$ROOT_DEVICE" 2>&1 </dev/null)
  fi || die "enrolling the TPM failed: $(hide_keys <<<"$ENROLL_OUT" | tail -n 1)"
  for s in $(tpm_slots bound); do [[ " $old " == *" $s "* ]] || slot=$s; done
  if ! tpm_unlocks; then
    [[ -n $slot ]] && systemd-cryptenroll --wipe-slot="$slot" "$ROOT_DEVICE" >/dev/null 2>&1
    die "the TPM was enrolled but doesn't open the disk, so it was removed again. The recovery key and passphrase still work."
  fi
  if [[ -n $old ]]; then
    systemd-cryptenroll --wipe-slot="${old// /,}" "$ROOT_DEVICE" >/dev/null 2>&1 &&
      log "the TPM was enrolled afresh: the firmware or its Secure Boot keys changed since the last time" ||
      log "WARNING: the old TPM enrollment could not be removed (it no longer opens the disk anyway)"
  else
    log "the TPM now unlocks the disk at boot while Secure Boot is on with this laptop's keys"
  fi
}

# --- the one-time unlock ------------------------------------------------------------------------------------------
# setup can't bind the TPM to PCR 7 yet (Secure Boot is on only from the restart), so it leaves a TPM unlock
# bound to nothing: the restart needs nobody at the keyboard. At that start, `finish` (run by FINISH_UNIT) binds the
# TPM to PCR 7 and removes it, whatever happens. Until then the disk opens by itself on this laptop: one start.
FINISH_UNIT=monarchy-encryption-finish.service
FINISH_LINK="$ETC/systemd/system/multi-user.target.wants/$FINISH_UNIT"

# Adds the one-time unlock (with DISK_SECRET), proves it opens the disk, and has finish run at the next start.
one_time_unlock_add() {
  if [[ -z $(tpm_slots one-time) ]]; then
    local t ok=0
    enroll_with_secret --tpm2-device=auto --tpm2-pcrs= ||
      die "enrolling the TPM for the restart failed: $(hide_keys <<<"$ENROLL_OUT" | tail -n 1)"
    for t in $(tpm_tokens one-time); do token_opens "$t" && ok=1; done
    if ((!ok)); then
      one_time_unlock_remove
      die "the TPM was enrolled for the restart but doesn't open the disk, so it was removed again"
    fi
  fi
  [[ -L $FINISH_LINK ]] && return 0
  mkdir -p "$(dirname "$FINISH_LINK")"
  ln -sfn "/usr/lib/systemd/system/$FINISH_UNIT" "$FINISH_LINK"
}
# Removes the one-time unlock, and finish's link. The passphrase and the recovery key, each proven by setup, are still
# there unless the TPM took the passphrase's place (remove_passphrases).
one_time_unlock_remove() {
  local slots; slots=$(tpm_slots one-time)
  rm -f "$FINISH_LINK"
  [[ -n $slots ]] || return 0
  systemd-cryptenroll --wipe-slot="${slots// /,}" "$ROOT_DEVICE" >/dev/null 2>&1 &&
    log "the disk no longer opens by itself without Secure Boot (setup's one-time unlock was removed)" ||
    log "WARNING: setup's one-time unlock could not be removed: run setup again"
}

# Run by FINISH_UNIT at the start after setup, with nobody to answer: the TPM bound to PCR 7 (unlocked by the one-time
# unlock) and the passphrase removed, then the one-time unlock removed in any case. Never a recovery key: its output
# goes to the journal, and there's nobody to hand it to.
cmd_finish() {
  [[ $# -eq 0 ]] || { usage >&2; exit 1; }
  rm -f "$FINISH_LINK"   # once
  find_root_disk || return 0
  [[ -n $(tpm_slots one-time) ]] || { log "setup has nothing to finish"; return 0; }
  trap one_time_unlock_remove EXIT
  if ! secure_boot_active; then
    log "WARNING: the laptop started without Secure Boot on with its own keys, so setup can't finish: the disk asks \
for its passphrase from the next start. Turn Secure Boot on in the firmware settings, then run setup again."
    return 0
  fi
  tpm_check
  tpm_setup
  local passphrase; passphrase=$(remove_passphrases)
  log "setup finished: the TPM unlocks the disk at boot while Secure Boot is on$([[ $passphrase == kept ]] &&
    echo "; the disk passphrase still works (no recovery key: run recovery-key, then setup with it)")"
}

# Removes the passphrases (keyslots with no token) once the TPM and the recovery key each open the disk. The proof for
# the second: DISK_SECRET is the recovery key, or setup made it and handed it over. Prints kept/removed/none.
remove_passphrases() {
  local slots; slots=$(passphrase_slots)
  [[ -n $slots ]] || { echo none; return; }
  # The one-time unlock is there only after setup handed over the recovery key (printed counts as delivered).
  if ! { [[ -n $(tpm_slots one-time) && -n $(luks_token_slots systemd-recovery) ]] || secret_is_recovery_key; }; then
    echo kept; return
  fi
  tpm_unlocks || die "the TPM doesn't open the disk, so the passphrase was kept"
  systemd-cryptenroll --wipe-slot="${slots// /,}" "$ROOT_DEVICE" >/dev/null 2>&1 ||
    die "removing the disk passphrase failed. The TPM and the recovery key still open the disk."
  [[ -z $(passphrase_slots) ]] || die "the disk passphrase is still there after removing it"
  tpm_unlocks && { [[ -z ${DISK_SECRET:-} ]] || secret_opens; } || die "after removing the passphrase, the TPM or the recovery key no longer opens the disk"
  log "the disk passphrase was removed: the TPM and the recovery key open the disk"
  echo removed
}

# --- status -------------------------------------------------------------------------------------------------------
# Which keys open the disk: the TPM now (not only enrolled: after a firmware update it no longer matches), the PCRs it's
# bound to, setup's one-time unlock, a recovery key, a passphrase. The LUKS header is root-only: null for anyone else,
# or when / isn't on LUKS.
disk_keys_status_json() {
  if [[ $EUID -ne 0 || -z ${ROOT_DEVICE:-} ]]; then
    printf '"tpm_unlock":null,"tpm_enrolled":null,"tpm_pcrs":null,"one_time_unlock":null,"recovery_key":null,"passphrase":null'; return
  fi
  local pcrs
  pcrs=$(cryptsetup luksDump --dump-json-metadata "$ROOT_DEVICE" |
    jq -c '[.tokens[] | select(.type == "systemd-tpm2") | .["tpm2-pcrs"][]?] | unique | if . == [] then null else . end')
  printf '"tpm_unlock":%s,"tpm_enrolled":%s,"tpm_pcrs":%s,"one_time_unlock":%s,"recovery_key":%s,"passphrase":%s' \
    "$(json_bool tpm_unlocks)" "$(json_bool tpm_enrolled)" "$pcrs" "$(json_bool test -n "$(tpm_slots one-time)")" \
    "$(json_bool test -n "$(luks_token_slots systemd-recovery)")" "$(json_bool test -n "$(passphrase_slots)")"
}
