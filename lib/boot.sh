# The boot files the TPM measures, and a boot menu that can't be used to get around it. Sourced.
# Why each piece is here: docs/dev/architecture.md, "Measured boot".

EDITOR_HOOK="85-monarchy-encryption-editor"       # sorts before Limine's 90-limine-enroll-config
FALLBACK_HOOK="95-monarchy-encryption-fallback"   # sorts after it
POLICY_HOOK="96-monarchy-encryption-policy"       # after the fallback: the TPM policy follows the final files

# --- the boot menu ------------------------------------------------------------------------------------------------
# A disk the TPM unlocks is a root shell away if the kernel command line can be changed at boot, so: no editor, and
# Limine refuses a limine.conf whose checksum doesn't match the one enrolled into its binary. The TPM measures that
# binary, so the menu (command line included) is part of what it checks.
limine_conf() { echo "$(esp_path)/limine.conf"; }
limine_bin() { echo "$(esp_path)/EFI/limine/limine_x64.efi"; }
fallback_bin() { echo "$(esp_path)/EFI/BOOT/BOOTX64.EFI"; }
boot_images() { local f; for f in "$(esp_path)"/EFI/Linux/*.efi; do [[ -f $f ]] && echo "$f"; done; return 0; }

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

# Limine post hooks, run by Limine's tools on every update (snapshots included: limine-snapper-sync runs them too).
# The editor hook locks the editor again before the menu's checksum is enrolled (omarchy-refresh-limine brings it
# back). Limine's tools copy a plain Limine to the firmware's fallback path, which has no enrolled checksum, so
# choosing it in the firmware's boot menu would boot a changed limine.conf: the fallback hook replaces it with the
# enrolled one. The policy hook then tells the TPM about the files that will boot next.
install_limine_hooks() {
  local name src
  for name in "$EDITOR_HOOK:limine-editor" "$FALLBACK_HOOK:limine-fallback" "$POLICY_HOOK:limine-policy"; do
    src="$ME_ROOT/hooks/${name#*:}"
    [[ $(readlink "$ETC/boot/hooks/post.d/${name%%:*}" 2>/dev/null) == "$src" ]] && continue
    install -d -m 0755 "$ETC/boot/hooks/post.d"
    ln -sfn "$src" "$ETC/boot/hooks/post.d/${name%%:*}"
    CHANGED=1
  done
}
remove_limine_hooks() { rm -f "$ETC/boot/hooks/post.d/"{"$EDITOR_HOOK","$FALLBACK_HOOK","$POLICY_HOOK"}; }
fallback_protected() { cmp -s "$(limine_bin)" "$(fallback_bin)"; }

# The boot menu settings and hooks. The boot files are rebuilt (which also builds the initramfs) only when something
# changed (CHANGED, set by the initramfs part too) or the menu isn't protected, so running it again changes nothing.
# setup and reassert.
boot_maintain() {
  lock_editor
  enable_config_enroll
  install_limine_hooks
  if ((${CHANGED:-0})) || ! config_protected || ! fallback_protected; then
    local out
    out=$(limine-update 2>&1) || { printf '%s\n' "$out" | tail -20 >&2; die "rebuilding the boot files failed (limine-update)"; }
    CHANGED=1
  fi
}

# --- status -------------------------------------------------------------------------------------------------------
json_bool() { if "$@" 2>/dev/null; then echo true; else echo false; fi; }
boot_menu_status_json() { # root only: the ESP's menu can be read by anyone, but not the enrolled checksum's context
  local editor=null cfg=null fb=null
  if [[ $EUID -eq 0 ]]; then
    editor=$(json_bool editor_locked); cfg=$(json_bool config_protected); fb=$(json_bool fallback_protected)
  fi
  printf '"boot_menu":{"editor_locked":%s,"config_protected":%s,"fallback_protected":%s}' "$editor" "$cfg" "$fb"
}
