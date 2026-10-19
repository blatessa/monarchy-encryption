# The systemd initramfs that TPM unlock needs, in place of Omarchy's busybox one. Sourced.
# Why it looks like this: docs/dev/architecture.md, "A systemd initramfs (sd-encrypt), not Clevis".

DROPIN_NAME="zz-monarchy-encryption.conf"   # sorts after Omarchy's mkinitcpio drop-ins
dropin() { echo "$ETC/mkinitcpio.conf.d/$DROPIN_NAME"; }

# The encrypted disk / lives on: ROOT_MAPPING (the name under /dev/mapper, "root" on Omarchy), ROOT_DEVICE (the LUKS
# partition) and ROOT_LUKS_UUID.
# Fails when / isn't on LUKS.
find_root_disk() {
  local src dev
  src=$(findmnt -no SOURCE / 2>/dev/null) || return 1
  src=${src%%\[*}                                      # btrfs adds [/subvolume]
  [[ $src == /dev/mapper/* ]] || return 1
  ROOT_MAPPING=${src#/dev/mapper/}
  dev=$(cryptsetup status "$ROOT_MAPPING" 2>/dev/null | sed -n 's/^ *device: *//p')
  [[ -n $dev ]] || return 1
  ROOT_DEVICE=$dev
  ROOT_LUKS_UUID=$(cryptsetup luksUUID "$dev" 2>/dev/null) && [[ -n $ROOT_LUKS_UUID ]]
}

# Omarchy's factory reset writes "resume= resume_offset=N" (no device: it rebuilds hibernation in a chroot). The
# busybox initramfs ignores that; the systemd one waits for it forever and the laptop never mounts / (findings.md).
# limine-entry-tool appends drop-ins to the command line in reverse name order, so ours is named to land last, and
# systemd uses the last resume=.
RESUME_DROPIN_NAME="00-monarchy-encryption.conf"
resume_dropin() { echo "$ETC/limine-entry-tool.d/$RESUME_DROPIN_NAME"; }
resume_device_missing() {
  local files=("$ETC/default/limine" "$ETC"/limine-entry-tool.d/*.conf) text
  text=" $(grep -h 'KERNEL_CMDLINE' "${files[@]}" 2>/dev/null | grep -v -F "$RESUME_DROPIN_NAME" | tr '"' ' ' | tr '\n' ' ') "
  [[ $text == *" resume_offset="* && $text == *" resume= "* ]]
}

crypttab_line() { echo "$ROOT_MAPPING  UUID=$ROOT_LUKS_UUID  none  luks,x-initrd.attach"; }
crypttab_entry() { awk -v n="$1" '$1 == n' "$ETC/crypttab" 2>/dev/null; }   # the line for a mapping name, if any
# An existing line will do when it opens the same LUKS volume, with no key file, in the initramfs; more options
# (discard, and tpm2-device= once the TPM is enrolled) are fine.
crypttab_entry_ok() {
  local name dev key opts
  read -r name dev key opts <<<"$1"
  [[ $name == "$ROOT_MAPPING" && $dev == "UUID=$ROOT_LUKS_UUID" && ($key == none || $key == -) && ,$opts, == *,x-initrd.attach,* ]]
}

# Omarchy's first-boot provisioning is pending (a deferred install, or a factory reset): the disk unlocks with a key
# file through cryptkey=, which only the busybox initramfs reads (findings.md). Switching now would leave a disk that
# asks for a passphrase nobody knows, and provisioning's re-key would remove our keyslots anyway.
provisioning_pending() {
  [[ -e $OMARCHY_PROVISIONING/pending || -e $ETC/omarchy/provisioning.key ||
    -e $ETC/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf ||
    -e $ETC/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf ]]
}

# Refuses before anything is changed: called by setup up front.
initramfs_check() {
  provisioning_pending && die "Omarchy's first-boot setup hasn't finished on this laptop: its disk still unlocks with \
the key file that setup provides, which the boot environment TPM unlock needs can't use. Finish first-boot setup \
(create the user at the first start), then run setup again. Nothing was changed."
  find_root_disk || die "this laptop's disk isn't encrypted (/ is not on a LUKS volume), so there is nothing to unlock"
  local have; have=$(crypttab_entry "$ROOT_MAPPING")
  if [[ -n $have ]] && ! crypttab_entry_ok "$have"; then
    die "$ETC/crypttab already describes the disk '$ROOT_MAPPING' differently ($have). Remove that line or make it \
'$(crypttab_line)', then run setup again. Nothing was changed."
  fi
}

# Writes the drop-in and the crypttab line; sets CHANGED when it changed either. The boot image is rebuilt later.
initramfs_apply() {
  local want; want=$(cat "$ME_ROOT/data/$DROPIN_NAME")
  if [[ ! -f $(dropin) || $(cat "$(dropin)") != "$want" ]]; then
    install -d -m 0755 "$(dirname "$(dropin)")"
    printf '%s\n' "$want" > "$(dropin)"; chmod 0644 "$(dropin)"
    CHANGED=1
  fi
  if [[ -z $(crypttab_entry "$ROOT_MAPPING") ]]; then
    printf '%s: the disk, opened by the systemd initramfs\n%s\n' "$ME_MARK" "$(crypttab_line)" >> "$ETC/crypttab"
    CHANGED=1
  fi
  if resume_device_missing && [[ ! -f $(resume_dropin) ]]; then
    install -d -m 0755 "$(dirname "$(resume_dropin)")"
    printf '%s: hibernation names no device (an Omarchy factory reset); the systemd initramfs needs one\nKERNEL_CMDLINE[default]+=" resume=/dev/mapper/%s"\n' \
      "$ME_MARK" "$ROOT_MAPPING" > "$(resume_dropin)"
    CHANGED=1
  fi
  local hooks; hooks=" $(initramfs_hooks) "
  [[ $hooks == *" sd-encrypt "* && $hooks != *" encrypt "* ]] || die "the initramfs settings still don't use sd-encrypt (hooks:$hooks)"
}

# The HOOKS mkinitcpio will use: its config and drop-ins sourced in its order, in a subshell.
initramfs_hooks() {
  (
    set +eu
    export LC_ALL=C                               # drop-ins in mkinitcpio's order
    # shellcheck disable=SC2034  # FILES and MODULES are read by the sourced files
    HOOKS=() FILES=() MODULES=()
    [[ -f $ETC/mkinitcpio.conf ]] && source "$ETC/mkinitcpio.conf" >/dev/null 2>&1
    for f in "$ETC"/mkinitcpio.conf.d/*.conf; do
      # shellcheck disable=SC1090
      [[ -f $f ]] && source "$f" >/dev/null 2>&1
    done
    echo "${HOOKS[*]}"
  )
}

initramfs_status_json() { # crypttab and the LUKS header are root-only: null for anyone else
  local pending; pending=$(json_bool provisioning_pending)   # file names only: anyone can see them
  [[ $EUID -eq 0 ]] || { printf '"disk":{"encrypted":null,"systemd_initramfs":null,"provisioning_pending":%s,%s}' "$pending" "$(disk_keys_status_json)"; return; }
  local enc=false sd=false hooks
  find_root_disk && enc=true
  hooks=" $(initramfs_hooks) "
  [[ $hooks == *" sd-encrypt "* && $hooks != *" encrypt "* && -n $(crypttab_entry "${ROOT_MAPPING:-root}") ]] && sd=true
  printf '"disk":{"encrypted":%s,"systemd_initramfs":%s,"provisioning_pending":%s,%s}' "$enc" "$sd" "$pending" "$(disk_keys_status_json)"
}
