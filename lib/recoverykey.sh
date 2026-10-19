# The recovery key: a computer-generated passphrase in its own keyslot, printed once for the caller. Sourced.
# Why it looks like this: docs/dev/architecture.md, "The recovery key".

RECOVERY_KEY_RE='[a-z]{8}(-[a-z]{8}){7}'   # systemd-cryptenroll's format: 8 groups of 8 modhex letters
hide_keys() { sed -E "s/$RECOVERY_KEY_RE/<recovery key>/g"; }   # for anything shown when something failed

# The keyslots systemd-cryptenroll tagged with a token of this type (systemd-recovery, systemd-tpm2), space-separated.
luks_token_slots() {
  cryptsetup luksDump --dump-json-metadata "$ROOT_DEVICE" |
    jq -r --arg t "$1" '[.tokens[] | select(.type == $t) | .keyslots[]] | sort | join(" ")'
}

# Adds a recovery keyslot; prints systemd-cryptenroll's stdout and stderr together, where the key shares a line with
# other text (findings.md), so it's found by RECOVERY_KEY_RE. It needs a key the disk already opens with: the TPM when
# it's enrolled, else the disk passphrase (or the current recovery key), asked for on a terminal or read as one line
# from stdin. The passphrase reaches systemd-cryptenroll through a pipe, never a file or the environment; its own
# prompt doesn't read piped input (findings.md).
recovery_key_enroll() {
  local out pass
  if [[ -n $(luks_token_slots systemd-tpm2) ]] &&
    out=$(systemd-cryptenroll --unlock-tpm2-device=auto --recovery-key "$ROOT_DEVICE" 2>&1 </dev/null); then
    printf '%s\n' "$out"; return
  fi
  if [[ -t 0 ]]; then
    read -rsp "Disk passphrase (or the current recovery key): " pass; echo >&2
  else
    IFS= read -r pass || true
  fi
  [[ -n $pass ]] || die "the disk passphrase is needed to add a recovery key: type it when asked, or give it on stdin (one line). Nothing was changed."
  if ! out=$(printf '%s' "$pass" | systemd-cryptenroll --unlock-key-file=/dev/stdin --recovery-key "$ROOT_DEVICE" 2>&1); then
    die "that passphrase doesn't open the disk, so no recovery key was added. Nothing was changed. ($(hide_keys <<<"$out" | tail -n 1))"
  fi
  printf '%s\n' "$out"
}

# Creates the recovery key, or replaces the one there is: add the new one, prove it opens the disk, hand it over, then
# remove the old one. The key goes to stdout only (with --json, in JSON); nothing logs it.
cmd_recovery_key() {
  local json=0
  [[ $# -eq 0 || ($# -eq 1 && $1 == --json) ]] || { usage >&2; exit 1; }
  [[ ${1:-} == --json ]] && json=1
  find_root_disk || die "this laptop's disk isn't encrypted (/ is not on a LUKS volume), so it has no recovery key"

  local old out key slot previous=none s
  old=$(luks_token_slots systemd-recovery)
  out=$(recovery_key_enroll)
  for s in $(luks_token_slots systemd-recovery); do [[ " $old " == *" $s "* ]] || slot=$s; done
  [[ -n ${slot:-} ]] || die "systemd-cryptenroll added no recovery key: $(hide_keys <<<"$out" | tail -n 1). Nothing was changed."
  key=$(grep -oE "$RECOVERY_KEY_RE" <<<"$out" | tail -n 1) || true
  if [[ -z $key ]]; then   # a slot whose key nobody has is only a way in for whoever finds it
    systemd-cryptenroll --wipe-slot="$slot" "$ROOT_DEVICE" >/dev/null 2>&1 || true
    die "the new recovery key couldn't be read from systemd-cryptenroll's output, so it was removed again. Any previous recovery key still works."
  fi

  if ! printf '%s' "$key" | cryptsetup open --test-passphrase --key-file=- --key-slot="$slot" "$ROOT_DEVICE" >/dev/null 2>&1; then
    systemd-cryptenroll --wipe-slot="$slot" "$ROOT_DEVICE" >/dev/null 2>&1 || true
    die "the new recovery key didn't open the disk, so it was removed again. Any previous recovery key still works."
  fi

  # The new key works: removing the old one can't lock anyone out. A failure here still hands over the new key.
  if [[ -n $old ]]; then
    if systemd-cryptenroll --wipe-slot="${old// /,}" "$ROOT_DEVICE" >/dev/null 2>&1; then previous=removed
    else previous=not_removed; log "WARNING: the previous recovery key could not be removed and still opens the disk; run recovery-key again"; fi
  fi
  log "recovery key $([[ $previous == none ]] && echo created || echo replaced)"

  if ((json)); then
    jq -cn --arg k "$key" --arg p "$previous" '{schema: 1, recovery_key: $k, previous_key: $p}'
    return
  fi
  {
    echo "This laptop's disk recovery key (shown only now; store it before you close this window):"
    echo
  } >&2
  printf '%s\n' "$key"
  {
    echo
    echo "Type it at the disk prompt when the laptop can't unlock the disk by itself."
    case $previous in
      removed) echo "The previous recovery key no longer works." ;;
      not_removed) echo "The previous recovery key could not be removed and still works: run recovery-key again." ;;
    esac
  } >&2
}
