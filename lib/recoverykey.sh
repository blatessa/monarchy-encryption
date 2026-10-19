# The recovery key: a computer-generated passphrase in its own keyslot, printed once for the caller. Sourced.
# Why it looks like this: docs/dev/architecture.md, "The recovery key".

RECOVERY_KEY_RE='[a-z]{8}(-[a-z]{8}){7}'   # systemd-cryptenroll's format: 8 groups of 8 modhex letters
hide_keys() { sed -E "s/$RECOVERY_KEY_RE/<recovery key>/g"; }   # for anything shown when something failed

# The keyslots systemd-cryptenroll tagged with a token of this type (systemd-recovery, systemd-tpm2), space-separated.
luks_token_slots() {
  cryptsetup luksDump --dump-json-metadata "$ROOT_DEVICE" |
    jq -r --arg t "$1" '[.tokens[] | select(.type == $t) | .keyslots[]] | sort | join(" ")'
}
# Keyslots with no token: passphrases typed by a person (the installer's, or one added with cryptsetup).
passphrase_slots() {
  cryptsetup luksDump --dump-json-metadata "$ROOT_DEVICE" |
    jq -r '([.keyslots | keys[]] - [.tokens[].keyslots[]]) | sort | join(" ")'
}

# --- the key the caller gives ----------------------------------------------------------------------------------
# DISK_SECRET: the disk passphrase or the current recovery key, asked for on a terminal or read as one line from
# stdin; kept in memory only. It reaches cryptsetup and systemd-cryptenroll through a pipe, never a file or the
# environment: systemd-cryptenroll's own prompt doesn't read piped input (findings.md).
read_disk_secret() {
  [[ -n ${DISK_SECRET:-} ]] && return 0
  if [[ -t 0 ]]; then
    read -rsp "Recovery key or disk passphrase: " DISK_SECRET; echo >&2
  else
    IFS= read -r DISK_SECRET || true
  fi
  [[ -n $DISK_SECRET ]] || die "this needs the disk's recovery key or passphrase: type it when asked, or give it on stdin (one line). Nothing was changed."
}
# key_opens KEY [SLOT]: KEY opens the disk (with that keyslot). Tokens are left out: cryptsetup tries the TPM first and
# reports success whatever key it was given (findings.md).
key_opens() {
  printf '%s' "$1" | cryptsetup open --test-passphrase --disable-external-tokens --key-file=- ${2:+--key-slot="$2"} \
    "$ROOT_DEVICE" >/dev/null 2>&1
}
secret_opens() { key_opens "$DISK_SECRET" "${1:-}"; }   # secret_opens [SLOT]: DISK_SECRET opens the disk
check_disk_secret() { # refuses before anything is changed
  read_disk_secret
  secret_opens || die "that recovery key or passphrase doesn't open the disk. Nothing was changed."
}
# secret_is_recovery_key: DISK_SECRET is the recovery key (not a passphrase): proof the caller has stored it.
secret_is_recovery_key() {
  local s; for s in $(luks_token_slots systemd-recovery); do secret_opens "$s" && return 0; done; return 1
}
# enroll_with_secret ARGS...: systemd-cryptenroll ARGS on the disk, unlocked with DISK_SECRET; output in ENROLL_OUT.
enroll_with_secret() {
  ENROLL_OUT=$(printf '%s' "$DISK_SECRET" | systemd-cryptenroll --unlock-key-file=/dev/stdin "$@" "$ROOT_DEVICE" 2>&1)
}

# --- adding a key ------------------------------------------------------------------------------------------------
# Adds a recovery key and proves it opens the disk; sets RECOVERY_KEY (in memory only) and RECOVERY_OLD (the
# recovery slots there were before, for the caller to remove). Unlocked by the TPM when it's enrolled and no secret
# was given, else by DISK_SECRET. systemd-cryptenroll prints the key in the middle of a line of other text
# (findings.md), so it's found by RECOVERY_KEY_RE. A slot whose key can't be read or doesn't open the disk is
# removed again: nobody would have its key.
recovery_key_add() {
  local s slot=""
  RECOVERY_OLD=$(luks_token_slots systemd-recovery)
  if [[ -z ${DISK_SECRET:-} && -n $(luks_token_slots systemd-tpm2) ]] &&
    ENROLL_OUT=$(systemd-cryptenroll --unlock-tpm2-device=auto --recovery-key "$ROOT_DEVICE" 2>&1 </dev/null); then
    :
  else
    read_disk_secret
    enroll_with_secret --recovery-key ||
      die "that recovery key or passphrase doesn't open the disk, so no recovery key was added. Nothing was changed. ($(hide_keys <<<"$ENROLL_OUT" | tail -n 1))"
  fi
  for s in $(luks_token_slots systemd-recovery); do [[ " $RECOVERY_OLD " == *" $s "* ]] || slot=$s; done
  [[ -n $slot ]] || die "systemd-cryptenroll added no recovery key: $(hide_keys <<<"$ENROLL_OUT" | tail -n 1). Nothing was changed."
  RECOVERY_KEY=$(grep -oE "$RECOVERY_KEY_RE" <<<"$ENROLL_OUT" | tail -n 1) || true
  if [[ -z $RECOVERY_KEY ]]; then
    systemd-cryptenroll --wipe-slot="$slot" "$ROOT_DEVICE" >/dev/null 2>&1 || true
    die "the new recovery key couldn't be read from systemd-cryptenroll's output, so it was removed again. Any previous recovery key still works."
  fi
  if ! key_opens "$RECOVERY_KEY" "$slot"; then
    systemd-cryptenroll --wipe-slot="$slot" "$ROOT_DEVICE" >/dev/null 2>&1 || true
    die "the new recovery key didn't open the disk, so it was removed again. Any previous recovery key still works."
  fi
}

# show_recovery_key: the key on stdout, how to use it on stderr (for a person; --json callers get it in JSON).
show_recovery_key() {
  printf "This laptop's disk recovery key (shown only now; store it before you close this window):\n\n" >&2
  printf '%s\n' "$RECOVERY_KEY"
  printf "\nType it at the disk prompt when the laptop can't unlock the disk by itself.\n" >&2
}

# Creates the recovery key, or replaces the one there is: add the new one, prove it opens the disk, hand it over, then
# remove the old one. The key goes to stdout only (with --json, in JSON); nothing logs it.
cmd_recovery_key() {
  local json=0 previous=none
  [[ $# -eq 0 || ($# -eq 1 && $1 == --json) ]] || { usage >&2; exit 1; }
  [[ ${1:-} == --json ]] && json=1
  find_root_disk || die "this laptop's disk isn't encrypted (/ is not on a LUKS volume), so it has no recovery key"
  recovery_key_add

  # The new key works: removing the old one can't lock anyone out. A failure here still hands over the new key.
  if [[ -n $RECOVERY_OLD ]]; then
    if systemd-cryptenroll --wipe-slot="${RECOVERY_OLD// /,}" "$ROOT_DEVICE" >/dev/null 2>&1; then previous=removed
    else previous=not_removed; log "WARNING: the previous recovery key could not be removed and still opens the disk; run recovery-key again"; fi
  fi
  log "recovery key $([[ $previous == none ]] && echo created || echo replaced)"

  if ((json)); then
    jq -cn --arg k "$RECOVERY_KEY" --arg p "$previous" '{schema: 1, recovery_key: $k, previous_key: $p}'
    return
  fi
  show_recovery_key
  case $previous in
    removed) echo "The previous recovery key no longer works." >&2 ;;
    not_removed) echo "The previous recovery key could not be removed and still works: run recovery-key again." >&2 ;;
  esac
}
