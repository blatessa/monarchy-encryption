# Secure Boot with this laptop's own keys, and a boot menu that can't be used to get around it. Sourced.
# Why each piece is here: docs/dev/architecture.md, "Secure Boot".

EDITOR_HOOK="85-monarchy-encryption-editor"       # sorts before Limine's 90-limine-enroll-config
FALLBACK_HOOK="95-monarchy-encryption-fallback"   # sorts after it

hex_of() { od -An -v -tx1 "$1" | tr -d ' \n'; }
efi_flag() { # efi_flag NAME: true/false from a one-byte UEFI global variable (SecureBoot, SetupMode), "" if absent
  local f="$EFIVARS/$1-$EFI_GLOBAL" b
  [[ -r $f ]] || return 0
  b=$(od -An -tu1 -j4 -N1 "$f" | tr -d ' ')
  [[ $b == 1 ]] && echo true || echo false
}

# The firmware's Platform Key is this laptop's sbctl key (its certificate is in the PK variable). Root only.
own_keys_enrolled() {
  local var="$EFIVARS/PK-$EFI_GLOBAL" pem="$SBCTL_DIR/keys/PK/PK.pem" der
  [[ -r $var && -r $pem ]] || return 1
  der=$(openssl x509 -in "$pem" -outform DER 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
  [[ -n $der && $(hex_of "$var") == *"$der"* ]]
}
microsoft_keys_enrolled() { [[ -r $EFIVARS/KEK-$EFI_GLOBAL ]] && grep -aq "Microsoft Corporation KEK" "$EFIVARS/KEK-$EFI_GLOBAL"; }

# --- the boot menu ------------------------------------------------------------------------------------------------
# A disk the TPM unlocks is a root shell away if the kernel command line can be changed at boot, so: no editor, and
# Limine refuses a limine.conf whose checksum doesn't match the one enrolled into its (signed) binary.
limine_conf() { echo "$(esp_path)/limine.conf"; }
limine_bin() { echo "$(esp_path)/EFI/limine/limine_x64.efi"; }
fallback_bin() { echo "$(esp_path)/EFI/BOOT/BOOTX64.EFI"; }

editor_locked() { grep -qx 'editor_enabled: no' "$(limine_conf)" 2>/dev/null; }
lock_editor() { # in limine.conf itself; Limine's tools keep the lines above the boot entries
  local c; c=$(limine_conf)
  [[ -f $c ]] || die "no Limine menu at $c: is this an Omarchy laptop?"
  editor_locked && return 0
  CHANGED=1
  if grep -q '^editor_enabled:' "$c"; then
    sed -i 's/^editor_enabled:.*/editor_enabled: no/' "$c"
  else
    sed -i "1i $ME_MARK: boot entries can't be edited at the menu\neditor_enabled: no" "$c"
  fi
}

# Limine's tools read this one setting only from /etc/default/limine, never from a drop-in.
config_enroll_enabled() { grep -qx 'ENABLE_ENROLL_LIMINE_CONFIG=yes' "$ETC/default/limine" 2>/dev/null; }
enable_config_enroll() {
  local f="$ETC/default/limine"
  config_enroll_enabled && return 0
  CHANGED=1
  if grep -q '^ENABLE_ENROLL_LIMINE_CONFIG=' "$f" 2>/dev/null; then
    sed -i 's/^ENABLE_ENROLL_LIMINE_CONFIG=.*/ENABLE_ENROLL_LIMINE_CONFIG=yes/' "$f"
  else
    printf '\n%s: Limine refuses a limine.conf changed behind its back\nENABLE_ENROLL_LIMINE_CONFIG=yes\n' "$ME_MARK" >> "$f"
  fi
}
config_protected() { # the Limine binary carries the checksum of the current limine.conf (enrolled as hex text)
  local h; h=$(b2sum "$(limine_conf)" 2>/dev/null | cut -d' ' -f1)
  [[ -n $h ]] && grep -aqF "$h" "$(limine_bin)" 2>/dev/null
}

# Limine post hooks, run by Limine's tools on every update. The editor hook locks the editor again before the menu's
# checksum is enrolled (omarchy-refresh-limine brings it back). Limine's tools copy a plain Limine to the firmware's
# fallback path, which has no enrolled checksum, so choosing it in the firmware's boot menu would boot a changed
# limine.conf: the fallback hook replaces it with the enrolled one.
install_limine_hooks() {
  local name src
  for name in "$EDITOR_HOOK:limine-editor" "$FALLBACK_HOOK:limine-fallback"; do
    src="$ME_ROOT/hooks/${name#*:}"
    [[ $(readlink "$ETC/boot/hooks/post.d/${name%%:*}" 2>/dev/null) == "$src" ]] && continue
    install -d -m 0755 "$ETC/boot/hooks/post.d"
    ln -sfn "$src" "$ETC/boot/hooks/post.d/${name%%:*}"
    CHANGED=1
  done
}
fallback_protected() { cmp -s "$(limine_bin)" "$(fallback_bin)"; }

# --- signing ----------------------------------------------------------------------------------------------------
# Limine's tools sign with sbctl once its keys exist: limine-update builds the boot images (signed by sbctl's
# mkinitcpio hook), enrolls the menu's checksum into Limine and signs it; our hook then updates the fallback.
unsigned_boot_files() { # prints our boot files that aren't signed by this laptop's key (other systems' loaders are left out)
  local esp; esp=$(esp_path)
  sbctl verify --json 2>/dev/null | jq -r '.[] | select(.is_signed != 1) | .file_name' |
    grep -E "^$esp/EFI/(limine/limine_x64\.efi|BOOT/BOOTX64\.EFI|Linux/[^/]+\.efi)$" || true
}
sign_boot_files() {
  local out unsigned
  out=$(limine-update 2>&1) || { printf '%s\n' "$out" | tail -20 >&2; die "rebuilding and signing the boot files failed (limine-update)"; }
  unsigned=$(unsigned_boot_files)
  [[ -z $unsigned ]] || die "these boot files are still unsigned, so Secure Boot would refuse them: ${unsigned//$'\n'/ }"
}

# Each snapshot's boot menu entry starts a copy of the boot image from when it was taken, pinned by hash in
# limine-snapper-sync's records; a copy from before Secure Boot can't be signed without breaking that hash
# (docs/dev/findings.md). Those snapshots still restore from the running system; they just can't be started from the menu.
unbootable_snapshots() {
  local esp; esp=$(esp_path)
  sbctl verify --json 2>/dev/null | jq -r '.[] | select(.is_signed != 1) | .file_name' | grep -c "^$esp/[^/]*/limine_history/" || true
}
warn_unbootable_snapshots() {
  local n; n=$(unbootable_snapshots)
  ((n == 0)) || log "note: $n boot image(s) of snapshots taken before Secure Boot can't be started from the boot menu any more. \
Snapshots taken from now on can, and every snapshot can still be restored from the running system."
}

# --- setup --------------------------------------------------------------------------------------------------------
# Refuses before anything is changed: called by setup up front.
secureboot_check() {
  [[ -d $EFIVARS ]] || die "this laptop didn't start in UEFI mode, so it can't use Secure Boot"
  if [[ $(efi_flag SetupMode) != true ]] && ! own_keys_enrolled; then
    die "Secure Boot already has keys that aren't this laptop's own (usually the manufacturer's). In the firmware \
settings, reset or clear the Secure Boot keys so the firmware is in setup mode, then run setup again. Nothing was changed."
  fi
}

# The boot menu settings and hooks, and every boot file signed and protected. The boot files are rebuilt (which also
# builds the initramfs) only when something changed (CHANGED, set by the initramfs part too) or isn't signed and
# protected, so running it again changes nothing. Needs this laptop's keys; enrolls nothing. setup and reassert.
secureboot_maintain() {
  lock_editor
  enable_config_enroll
  install_limine_hooks
  if ((${CHANGED:-0})) || [[ -n $(unsigned_boot_files) ]] || ! config_protected || ! fallback_protected; then
    sign_boot_files
    CHANGED=1
  fi
}

# Everything is signed and checked before the keys go into the firmware: after that, nothing unsigned starts.
secureboot_setup() {
  local setup_mode; setup_mode=$(efi_flag SetupMode)
  if [[ ! -f $SBCTL_DIR/keys/PK/PK.pem ]]; then
    sbctl create-keys >/dev/null || die "creating this laptop's Secure Boot keys failed"
    log "created this laptop's Secure Boot keys"
    CHANGED=1
  fi
  secureboot_maintain
  warn_unbootable_snapshots
  if [[ $setup_mode == true ]]; then
    # Microsoft's keys stay alongside ours: graphics cards and other devices start firmware signed by Microsoft
    sbctl enroll-keys --microsoft >/dev/null || die "putting the keys into the firmware failed; the boot files are signed and the laptop still starts"
    log "Secure Boot keys enrolled: Secure Boot is on from the next start"
  fi
}

# --- status -------------------------------------------------------------------------------------------------------
json_bool() { if "$@" 2>/dev/null; then echo true; else echo false; fi; }
secureboot_status_json() { # values only root can know are null for anyone else
  local enabled setup_mode own=null editor=null cfg=null fb=null
  enabled=$(efi_flag SecureBoot); setup_mode=$(efi_flag SetupMode)
  if [[ $EUID -eq 0 ]]; then
    own=$(json_bool own_keys_enrolled)
    editor=$(json_bool editor_locked); cfg=$(json_bool config_protected); fb=$(json_bool fallback_protected)
  fi
  printf '"secure_boot":{"enabled":%s,"setup_mode":%s,"own_keys":%s,"microsoft_keys":%s},' \
    "${enabled:-false}" "${setup_mode:-false}" "$own" "$(json_bool microsoft_keys_enrolled)"
  printf '"boot_menu":{"editor_locked":%s,"config_protected":%s,"fallback_protected":%s}' "$editor" "$cfg" "$fb"
}
