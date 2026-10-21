# release: undo setup, so the laptop unlocks with a passphrase again and is a plain Omarchy laptop (before Omarchy's
# factory reset, or leaving management). Sourced. Why: docs/dev/architecture.md, "Provisioning and factory reset".

# NEW_PASSPHRASE: the disk passphrase the laptop gets back, typed twice on a terminal or one line on stdin. In memory
# only; it reaches cryptsetup through a pipe.
read_new_passphrase() {
  local again
  if [[ -t 0 ]]; then
    read -rsp "New disk passphrase: " NEW_PASSPHRASE; echo >&2
    read -rsp "Type it again: " again; echo >&2
    [[ $NEW_PASSPHRASE == "$again" ]] || die "the two passphrases differ. Nothing was changed."
  else
    IFS= read -r NEW_PASSPHRASE || true
  fi
  [[ -n $NEW_PASSPHRASE ]] || die "release needs a new disk passphrase: type it when asked, or give it on stdin (one line). Nothing was changed."
}

# Adds NEW_PASSPHRASE as a keyslot, unlocked by the TPM, or by the recovery key (DISK_SECRET, read next) when the TPM
# no longer opens the disk. Proves it opens the disk.
add_passphrase() {
  if tpm_unlocks; then
    printf '%s' "$NEW_PASSPHRASE" |
      cryptsetup luksAddKey --token-only --token-type systemd-tpm2 "$ROOT_DEVICE" /dev/stdin >/dev/null 2>&1 ||
      die "adding the new passphrase failed. Nothing was changed."
  else
    log "the TPM doesn't open the disk now, so the recovery key is needed to add the passphrase"
    check_disk_secret
    printf '%s' "$NEW_PASSPHRASE" |
      cryptsetup luksAddKey --key-file=<(printf '%s' "$DISK_SECRET") "$ROOT_DEVICE" /dev/stdin >/dev/null 2>&1 ||
      die "adding the new passphrase failed. Nothing was changed."
  fi
  key_opens "$NEW_PASSPHRASE" || die "the new passphrase was added but doesn't open the disk: nothing else was changed"
  log "added the new disk passphrase"
}

cmd_release() {
  [[ $# -eq 0 ]] || { usage >&2; exit 1; }
  find_root_disk || die "this laptop's disk isn't encrypted (/ is not on a LUKS volume)"
  local tpm; tpm=$(luks_token_slots systemd-tpm2)
  if [[ -z $tpm ]] && ! setup_has_run && ! policy_exists; then log "setup hasn't run on this laptop: nothing to release"; return 0; fi

  # 1. a passphrase that opens the disk, before anything else goes
  if [[ -n $(passphrase_slots) ]]; then
    log "the disk still has a passphrase: keeping it"
  else
    read_new_passphrase
    add_passphrase
  fi

  # 2. the TPM no longer opens the disk (nor setup's one-time unlock, if the restart after setup hasn't happened). A
  # passphrase (proven above, or kept) and the recovery key remain.
  if [[ -n $tpm ]]; then
    [[ -n $(passphrase_slots) ]] || die "the disk has no passphrase, so the TPM was kept"
    systemd-cryptenroll --wipe-slot="${tpm// /,}" "$ROOT_DEVICE" >/dev/null 2>&1 || die "removing the TPM from the disk failed"
    log "the TPM no longer unlocks the disk: it asks for the passphrase at start"
  fi

  # 3. the TPM policy gone (its NV index freed), and nothing keeps it up to date: the boot service and the Limine hooks
  # are unlinked, and reassert finds setup hasn't run
  policy_remove
  rm -f "$BOOT_LINK"
  remove_limine_hooks
  log "released: restart, and type the disk passphrase at the prompt. Omarchy's factory reset (omarchy-system-factory-reset) asks for it too; setup sets the laptop up again."
}
