# TPM unlock: the TPM opens the disk at boot, but only for the boot files this laptop measured (lib/pcrlock.sh).
# Sourced. Why it looks like this: docs/dev/architecture.md, "TPM unlock".

tpm_present() { [[ -e $TPM_DEVICE ]]; }
# The disk's TPM tokens: "bound" ones are the TPM unlock (the pcrlock policy, or PCRs); "one-time" ones, bound to
# nothing, are the unlock setup leaves for the restart after it (below). tpm_tokens KIND prints their token ids,
# tpm_slots KIND their keyslots.
tpm_tokens_json() {
  cryptsetup luksDump --dump-json-metadata "$ROOT_DEVICE" | jq -c --arg k "$1" '[.tokens | to_entries[]
    | select(.value.type == "systemd-tpm2"
      and ((.value.tpm2_pcrlock == true or (.value["tpm2-pcrs"] // [] | length > 0)) == ($k == "bound")))]'
}
tpm_tokens() { tpm_tokens_json "$1" | jq -r 'map(.key) | join(" ")'; }
tpm_slots() { tpm_tokens_json "$1" | jq -r '[.[].value.keyslots[]] | sort | join(" ")'; }
tpm_enrolled() { [[ -n $(tpm_slots bound) ]]; }
# The TPM opens the disk now, through the same token the initramfs uses (systemd's cryptsetup token plugin).
token_opens() { cryptsetup open --test-passphrase --token-only --token-id="$1" "$ROOT_DEVICE" </dev/null >/dev/null 2>&1; }
tpm_unlocks() { local t; for t in $(tpm_tokens bound); do token_opens "$t" && return 0; done; return 1; }

tpm_check() { # refuses before anything is changed
  tpm_present || die "this laptop has no TPM 2.0 (no $TPM_DEVICE), so it can't unlock its disk by itself. Turn the TPM \
on in the firmware settings (it may be called PTT or fTPM), then run setup again. Nothing was changed."
}

# Enrolls the TPM against the policy (unlocked with DISK_SECRET, or by the one-time unlock when no secret was given)
# unless it already opens the disk, and proves it does. A TPM slot that no longer opens the disk (its policy was
# replaced, or the TPM was cleared) is replaced: the new one is enrolled and proven first.
tpm_setup() {
  tpm_unlocks && return 0
  policy_exists || die "there is no TPM policy for this laptop's boot files yet: restart, then run setup again"
  local old s slot=""; old=$(tpm_slots bound)
  [[ -z $old ]] || policy_renew
  if [[ -n ${DISK_SECRET:-} ]]; then
    enroll_with_secret --tpm2-device=auto --tpm2-pcrlock="$POLICY_FILE"
  else
    ENROLL_OUT=$(systemd-cryptenroll --unlock-tpm2-device=auto --tpm2-device=auto --tpm2-pcrlock="$POLICY_FILE" "$ROOT_DEVICE" 2>&1 </dev/null)
  fi || die "enrolling the TPM failed: $(hide_keys <<<"$ENROLL_OUT" | tail -n 1)"
  for s in $(tpm_slots bound); do [[ " $old " == *" $s "* ]] || slot=$s; done
  if ! tpm_unlocks; then
    [[ -n $slot ]] && systemd-cryptenroll --wipe-slot="$slot" "$ROOT_DEVICE" >/dev/null 2>&1
    die "the TPM was enrolled but doesn't open the disk, so it was removed again. The recovery key still works."
  fi
  if [[ -n $old ]]; then
    systemd-cryptenroll --wipe-slot="${old// /,}" "$ROOT_DEVICE" >/dev/null 2>&1 &&
      log "the TPM was enrolled afresh: its previous enrollment no longer opened the disk" ||
      log "WARNING: the old TPM enrollment could not be removed (it no longer opens the disk anyway)"
  else
    log "the TPM now unlocks the disk at boot, for this laptop's own boot files"
  fi
}

# --- the one-time unlock ------------------------------------------------------------------------------------------
# setup can't make the policy yet: it comes from the event log of a start with the boot files setup built. So it leaves
# a TPM unlock bound to nothing (and to no policy: cryptenroll would pick pcrlock.json up by itself), and the restart
# needs nobody at the keyboard. At that start, `boot` (run by BOOT_UNIT) makes the policy, binds the TPM to it and
# removes the one-time unlock, whatever happens. Until then the disk opens by itself on this laptop: one start.

# Adds the one-time unlock (with DISK_SECRET), proves it opens the disk, and has boot run at every start.
one_time_unlock_add() {
  if [[ -z $(tpm_slots one-time) ]]; then
    local t ok=0
    enroll_with_secret --tpm2-device=auto --tpm2-pcrs= --tpm2-pcrlock= ||
      die "enrolling the TPM for the restart failed: $(hide_keys <<<"$ENROLL_OUT" | tail -n 1)"
    for t in $(tpm_tokens one-time); do token_opens "$t" && ok=1; done
    if ((!ok)); then
      one_time_unlock_remove
      die "the TPM was enrolled for the restart but doesn't open the disk, so it was removed again"
    fi
  fi
  link_boot_unit
}
link_boot_unit() {
  [[ -L $BOOT_LINK ]] && return 0
  mkdir -p "$(dirname "$BOOT_LINK")"
  ln -sfn "/usr/lib/systemd/system/$BOOT_UNIT" "$BOOT_LINK"
}
# Removes the one-time unlock. The passphrase and the recovery key, each proven by setup, are still there unless the
# TPM took the passphrase's place (remove_passphrases).
one_time_unlock_remove() {
  local slots; slots=$(tpm_slots one-time)
  [[ -n $slots ]] || return 0
  systemd-cryptenroll --wipe-slot="${slots// /,}" "$ROOT_DEVICE" >/dev/null 2>&1 &&
    log "the disk no longer opens by itself (setup's one-time unlock was removed)" ||
    log "WARNING: setup's one-time unlock could not be removed: run setup again"
}

# Run by BOOT_UNIT at every start, with nobody to answer. The policy is made from what this start measured: the boot
# files on the ESP are the ones that started. At the start after setup, it then finishes setup: the TPM bound to the
# policy (unlocked by the one-time unlock) and the passphrase removed, then the one-time unlock removed in any case.
# Never a recovery key: its output goes to the journal, and there's nobody to hand it to.
cmd_boot() {
  [[ $# -eq 0 ]] || { usage >&2; exit 1; }
  setup_has_run || return 0
  find_root_disk || return 0
  local made=1
  policy_booted || made=0
  install -d -m 0755 "$RUN_DIR"; : > "$RUN_DIR/booted"
  ((made)) || log "WARNING: the TPM policy couldn't be updated for this start's boot files ($POLICY_ERR)"
  [[ -n $(tpm_slots one-time) ]] || return 0
  trap one_time_unlock_remove EXIT
  if ((!made)); then
    log "WARNING: setup can't finish without a TPM policy: the disk asks for its passphrase from the next start. \
Run setup again (with the recovery key) after the next start."
    return 0
  fi
  tpm_check
  tpm_setup
  local passphrase; passphrase=$(remove_passphrases)
  log "setup finished: the TPM unlocks the disk at boot$([[ $passphrase == kept ]] &&
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
# Which keys open the disk: the TPM now (not only enrolled: a policy that no longer matches doesn't), setup's one-time
# unlock, a recovery key, a passphrase. The LUKS header is root-only: null for anyone else, or when / isn't on LUKS.
disk_keys_status_json() {
  if [[ $EUID -ne 0 || -z ${ROOT_DEVICE:-} ]]; then
    printf '"tpm_unlock":null,"tpm_enrolled":null,"one_time_unlock":null,"recovery_key":null,"passphrase":null'; return
  fi
  printf '"tpm_unlock":%s,"tpm_enrolled":%s,"one_time_unlock":%s,"recovery_key":%s,"passphrase":%s' \
    "$(json_bool tpm_unlocks)" "$(json_bool tpm_enrolled)" "$(json_bool test -n "$(tpm_slots one-time)")" \
    "$(json_bool test -n "$(luks_token_slots systemd-recovery)")" "$(json_bool test -n "$(passphrase_slots)")"
}
