# TPM unlock: the TPM opens the disk at boot, but only while Secure Boot is on with this laptop's keys (PCR 7).
# Sourced. Why it looks like this: docs/dev/architecture.md, "TPM unlock".

TPM_PCRS=7   # Secure Boot state: on/off and the enrolled keys. Survives kernel and Omarchy updates.

tpm_present() { [[ -e $TPM_DEVICE ]]; }
tpm_enrolled() { [[ -n $(luks_token_slots systemd-tpm2) ]]; }
# The TPM opens the disk now, through the same token the initramfs uses (systemd's cryptsetup token plugin).
tpm_unlocks() {
  cryptsetup open --test-passphrase --token-only --token-type systemd-tpm2 "$ROOT_DEVICE" </dev/null >/dev/null 2>&1
}
# PCR 7 means something only once the laptop has started with Secure Boot on and its own keys: enrolling before that
# restart would bind the disk to "Secure Boot off".
secure_boot_active() { [[ $(efi_flag SecureBoot) == true ]] && own_keys_enrolled; }

tpm_check() { # refuses before anything is changed
  tpm_present || die "this laptop has no TPM 2.0 (no $TPM_DEVICE), so it can't unlock its disk by itself. Turn the TPM \
on in the firmware settings (it may be called PTT or fTPM), then run setup again. Nothing was changed."
}

# Enrolls the TPM (unlocked with DISK_SECRET) unless it already opens the disk, and proves it does. A TPM slot that
# no longer matches (the firmware or its keys changed since) is replaced: the new one is enrolled and proven first.
tpm_setup() {
  tpm_unlocks && return 0
  local old s slot=""; old=$(luks_token_slots systemd-tpm2)
  enroll_with_secret --tpm2-device=auto --tpm2-pcrs="$TPM_PCRS" ||
    die "enrolling the TPM failed: $(hide_keys <<<"$ENROLL_OUT" | tail -n 1)"
  for s in $(luks_token_slots systemd-tpm2); do [[ " $old " == *" $s "* ]] || slot=$s; done
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

# Removes the passphrases (keyslots with no token) once the TPM and the recovery key each open the disk. DISK_SECRET
# being the recovery key is the proof for the second: it opens the disk, and the caller has stored it. Prints
# kept/removed/none.
remove_passphrases() {
  local slots; slots=$(passphrase_slots)
  [[ -n $slots ]] || { echo none; return; }
  if ! secret_is_recovery_key; then echo kept; return; fi
  tpm_unlocks || die "the TPM doesn't open the disk, so the passphrase was kept"
  systemd-cryptenroll --wipe-slot="${slots// /,}" "$ROOT_DEVICE" >/dev/null 2>&1 ||
    die "removing the disk passphrase failed. The TPM and the recovery key still open the disk."
  [[ -z $(passphrase_slots) ]] || die "the disk passphrase is still there after removing it"
  tpm_unlocks && secret_opens || die "after removing the passphrase, the TPM or the recovery key no longer opens the disk"
  log "the disk passphrase was removed: the TPM and the recovery key open the disk"
  echo removed
}

# --- status -------------------------------------------------------------------------------------------------------
# Which keys open the disk: the TPM now (not only enrolled: after a firmware update it no longer matches), the PCRs it's
# bound to, a recovery key, a passphrase. The LUKS header is root-only: null for anyone else, or when / isn't on LUKS.
disk_keys_status_json() {
  if [[ $EUID -ne 0 || -z ${ROOT_DEVICE:-} ]]; then
    printf '"tpm_unlock":null,"tpm_enrolled":null,"tpm_pcrs":null,"recovery_key":null,"passphrase":null'; return
  fi
  local pcrs
  pcrs=$(cryptsetup luksDump --dump-json-metadata "$ROOT_DEVICE" |
    jq -c '[.tokens[] | select(.type == "systemd-tpm2") | .["tpm2-pcrs"][]?] | unique | if . == [] then null else . end')
  printf '"tpm_unlock":%s,"tpm_enrolled":%s,"tpm_pcrs":%s,"recovery_key":%s,"passphrase":%s' \
    "$(json_bool tpm_unlocks)" "$(json_bool tpm_enrolled)" "$pcrs" \
    "$(json_bool test -n "$(luks_token_slots systemd-recovery)")" "$(json_bool test -n "$(passphrase_slots)")"
}
