# The TPM policy: the TPM opens the disk only for the boot files this laptop measured (PCR 4: Limine, which carries the
# menu's checksum, and the boot image; PCR 11: what the boot image's stub measured). systemd-pcrlock predicts the
# measurements from this start's event log and the files on the ESP, and keeps the policy in a TPM NV index, so an
# update changes the policy, not the disk's keyslots. Sourced. Why: docs/dev/architecture.md, "Measured boot".

POLICY_PCRS=(4 11)
POLICY_ERR=""   # what pcrlock said when the policy couldn't be written
LIMINE_COMPONENT=600-monarchy-encryption-limine.pcrlock.d   # after pcrlock's 500-separator, as the firmware measures
UKI_COMPONENT=650-monarchy-encryption-uki.pcrlock.d
BOOT_UNIT=monarchy-encryption-boot.service
BOOT_LINK="$ETC/systemd/system/multi-user.target.wants/$BOOT_UNIT"

setup_has_run() { [[ -L $BOOT_LINK ]]; }
policy_exists() { [[ -f $POLICY_FILE ]]; }
boot_file_hashes() { local f; for f in "$(limine_bin)" $(boot_images); do sha256sum "$f" | cut -d' ' -f1; done | sort -u; }

# The recovery PIN lets the policy be rewritten from a start that didn't match it: pcrlock's default PIN is sealed
# behind the policy itself, so one start from the disk prompt would leave a policy that can never be updated
# (findings.md). Root-only, on the encrypted disk, outside /root: limine-snapper-sync runs Limine's hooks with
# ProtectHome=yes. It unlocks writing the policy, not the disk.
recovery_pin_ensure() {
  [[ -s $STATE/pin ]] && return 0
  install -d -m 0700 "$STATE"
  (umask 077; head -c 32 /dev/urandom | base64 | tr -d '=+/\n' > "$STATE/pin")
}

# policy_lock VARIANT: describe the boot files now on the ESP as VARIANT ("booted" or "current"). The policy allows
# either variant of each, so an update keeps the start that's running recognised while it describes the next one.
policy_lock() {
  local v=$1 img i=0
  install -d -m 0755 "$PCRLOCK_DIR/$LIMINE_COMPONENT" "$PCRLOCK_DIR/$UKI_COMPONENT"
  rm -f "$PCRLOCK_DIR/$UKI_COMPONENT/$v-"*.pcrlock
  "$PCRLOCK" lock-pe "$(limine_bin)" --pcrlock="$PCRLOCK_DIR/$LIMINE_COMPONENT/$v.pcrlock" >/dev/null 2>&1 || return 1
  for img in $(boot_images); do
    "$PCRLOCK" lock-uki "$img" --pcrlock="$PCRLOCK_DIR/$UKI_COMPONENT/$v-$i.pcrlock" >/dev/null 2>&1 || return 1
    i=$((i + 1))
  done
  boot_file_hashes > "$STATE/$v.files"
}
# Writes the policy to the TPM. --strict: no policy at all rather than one that leaves out a PCR the firmware measured
# in a way pcrlock doesn't recognise. The PIN goes through the environment: pcrlock reads it from $PIN or a terminal.
policy_make() {
  local out
  recovery_pin_ensure
  out=$(PIN=$(cat "$STATE/pin") timeout 120 "$PCRLOCK" make-policy --no-pager --policy="$POLICY_FILE" $(printf -- '--pcr=%s ' "${POLICY_PCRS[@]}") \
    --strict=yes --recovery-pin=query </dev/null 2>&1) || { POLICY_ERR=$(grep -v '^$' <<<"$out" | tail -n 1); return 1; }
  local v covered=()
  for v in booted current; do [[ -f $STATE/$v.files ]] && covered+=("$STATE/$v.files"); done
  sort -u "${covered[@]}" /dev/null > "$STATE/policy.files"
}
policy_serialised() { # limine-snapper-sync can run Limine's hooks twice within a second
  install -d -m 0755 "$RUN_DIR"
  exec 9>"$RUN_DIR/policy.lock"
  flock 9
}

# At every start (the boot service): the files on the ESP are the ones that just started; the policy allows them only.
policy_booted() {
  policy_serialised
  rm -f "$PCRLOCK_DIR/$LIMINE_COMPONENT/"*.pcrlock "$PCRLOCK_DIR/$UKI_COMPONENT/"*.pcrlock "$STATE/current.files"
  policy_lock booted && policy_make
}
# After Limine's tools wrote new boot files (the policy hook, reassert): the policy allows them as well as the ones
# that started. Nothing to do before the first start after setup, which makes the first policy.
policy_refresh() {
  policy_exists || return 0
  policy_serialised
  policy_lock current && policy_make
}
policy_current() { # the policy covers every boot file now on the ESP
  policy_exists && [[ -f $STATE/policy.files ]] && [[ -z $(comm -23 <(boot_file_hashes) "$STATE/policy.files") ]]
}
policy_remove() {
  if policy_exists; then "$PCRLOCK" remove-policy --policy="$POLICY_FILE" >/dev/null 2>&1 || log "WARNING: removing the TPM policy failed"; fi
  rm -rf "${PCRLOCK_DIR:?}/$LIMINE_COMPONENT" "${PCRLOCK_DIR:?}/$UKI_COMPONENT" "$STATE"
}

# Refuses before anything is changed: the TPM can hold the policy, and pcrlock recognises everything the firmware
# measured into the policy's PCRs at this start, described by the boot files now on the ESP. Firmware that measures
# something else there (or boot files changed since this start) would leave the laptop asking for the recovery key.
pcrlock_check() {
  [[ -d $EFIVARS ]] || die "this laptop didn't start in UEFI mode, so its boot can't be measured. Nothing was changed."
  "$PCRLOCK" is-supported --quiet >/dev/null 2>&1 || die "this laptop's TPM can't hold the boot policy (it needs TPM 2.0 \
with PolicyAuthorizeNV, revision 1.38 or later). Nothing was changed."
}
pcrlock_predictable() {
  local d img i=0 ok=0
  d=$(mktemp -d)
  "$PCRLOCK" lock-pe "$(limine_bin)" --pcrlock="$d/$LIMINE_COMPONENT.pcrlock" >/dev/null 2>&1 &&
    for img in $(boot_images); do "$PCRLOCK" lock-uki "$img" --pcrlock="$d/$UKI_COMPONENT-$i.pcrlock" >/dev/null 2>&1; i=$((i + 1)); done &&
    "$PCRLOCK" predict --no-pager --components="$d" --components=/usr/lib/pcrlock.d $(printf -- '--pcr=%s ' "${POLICY_PCRS[@]}") \
      --strict=yes >/dev/null 2>&1 && ok=1
  rm -rf "$d"
  ((ok)) || die "the firmware's record of this start doesn't match the boot files on the disk, so the TPM can't be tied \
to them. If the laptop was updated since it started, restart it and run setup again. Nothing was changed."
}

# --- status -------------------------------------------------------------------------------------------------------
tpm_policy_status_json() { # root only
  local exists=null pcrs=null current=null
  if [[ $EUID -eq 0 ]]; then
    exists=$(json_bool policy_exists); current=$(json_bool policy_current)
    policy_exists && pcrs=$(jq -c '[.pcrValues[]?.pcr] | unique' "$POLICY_FILE" 2>/dev/null || echo null)
  fi
  printf '"tpm_policy":{"exists":%s,"pcrs":%s,"current":%s}' "$exists" "${pcrs:-null}" "$current"
}
