#!/bin/bash
# Make the lab's clean base: an unattended, encrypted Omarchy install from the release ISO, onto a fresh disk, with
# fresh firmware variables (Secure Boot in setup mode) and a fresh TPM. Takes about 10 minutes. Afterwards
# images/base/ is never written again; reset.sh copies it to images/lab/. Re-run only to move to a newer ISO.
#
# The ISO installs itself when it finds its configurator's output files on a drive labeled cidata (see omarchy-iso's
# README, "Unattended installs"). The files here mirror what its configurator writes for an encrypted full-disk install.
source "$(dirname "$0")/lib.sh"

[[ -f $ISO ]] || die "no ISO at $ISO: run test/vm/fetch-iso.sh"
[[ -f $KEY ]] || { mkdir -p "$(dirname "$KEY")"; ssh-keygen -q -t ed25519 -N "" -C monarchy-lab -f "$KEY"; }
vm_running "$BASE" && die "the base VM is running"
vm_running "$LAB" && die "the lab VM is running: test/vm/stop.sh first"

build_cidata() { # build_cidata DIR: the configurator's files and a FAT image labeled CIDATA, in DIR
  local d=$1/cidata hash mib=$((1024 * 1024)) gib=$((1024 * 1024 * 1024))
  local disk_bytes=$((40 * gib)) boot_start=$mib boot_size=$((2 * gib))
  local main_start=$((boot_start + boot_size)); local main_size=$((disk_bytes - main_start - mib))
  rm -rf "$d"; mkdir -p "$d"
  hash=$(openssl passwd -6 "$LAB_PASSWORD")
  # archinstall takes the disk passphrase from here: with it only in disk_encryption below, the disk is silently left
  # unencrypted (docs/dev/findings.md)
  jq -n --arg h "$hash" --arg u "$LAB_USER" --arg pw "$LAB_PASSWORD" \
    '{encryption_password: $pw, root_enc_password: $h, users: [{enc_password: $h, groups: [], sudo: true, username: $u}]}' \
    > "$d/user_credentials.json"
  jq -n --arg host "$LAB_HOSTNAME" --arg pw "$LAB_PASSWORD" \
    --argjson bs "$boot_start" --argjson bz "$boot_size" --argjson ms "$main_start" --argjson mz "$main_size" '
    def size(v): {sector_size: {unit: "B", value: 512}, unit: "B", value: v};
    {
      app_config: null, "archinstall-language": "English", auth_config: {}, audio_config: {audio: "pipewire"},
      bootloader_config: {bootloader: "Limine", uki: false, removable: false}, custom_commands: [],
      omarchy_install: {
        mode: "full_disk", defer_provisioning: false, target_mount: "/mnt",
        boot: {esp_mount: "/boot", esp_path: "/EFI/limine", efi_binary: "limine_x64.efi", enable_fallback: true},
        storage: {kernel: "linux-omarchy"}
      },
      disk_config: {
        config_type: "default_layout",
        device_modifications: [{
          device: "/dev/vda", wipe: true,
          partitions: [
            {btrfs: [], dev_path: null, flags: ["boot", "esp"], fs_type: "fat32", mount_options: [], mountpoint: "/boot",
             obj_id: "ea21d3f2-82bb-49cc-ab5d-6f81ae94e18d", size: size($bz), start: size($bs), status: "create",
             type: "primary"},
            {btrfs: [{mountpoint: "/", name: "@"}, {mountpoint: "/home", name: "@home"},
                     {mountpoint: "/var/log", name: "@log"}, {mountpoint: "/var/cache/pacman/pkg", name: "@pkg"}],
             dev_path: null, flags: [], fs_type: "btrfs", mount_options: ["compress=zstd"], mountpoint: null,
             obj_id: "8c2c2b92-1070-455d-b76a-56263bab24aa", size: size($mz), start: size($ms), status: "create",
             type: "primary"}
          ]
        }],
        disk_encryption: {encryption_type: "luks", lvm_volumes: [], iter_time: 2000,
                          partitions: ["8c2c2b92-1070-455d-b76a-56263bab24aa"], encryption_password: $pw}
      },
      hostname: $host, kernels: ["linux-omarchy"], network_config: {type: "iso"}, ntp: true, parallel_downloads: 8,
      script: null, services: [], swap: true, timezone: "UTC",
      locale_config: {kb_layout: "us", sys_enc: "UTF-8", sys_lang: "en_US.UTF-8"},
      mirror_config: {
        custom_repositories: [], mirror_regions: {}, optional_repositories: [],
        custom_servers: [{url: "https://mirror.omarchy.org/$repo/os/$arch"},
                         {url: "https://geo.mirror.pkgbuild.com/$repo/os/$arch"}]
      },
      packages: ["base-devel", "git", "omarchy-keyring", "omarchy-settings", "omarchy"],
      profile_config: {gfx_driver: null, greeter: null, profile: {}},
      version: "3.0.9"
    }' > "$d/user_configuration.json"
  echo "Monarchy Lab" > "$d/user_full_name.txt"
  echo "lab@monarchy.test" > "$d/user_email_address.txt"
  echo true > "$d/user_encrypt_installation.txt"
  cp "$KEY.pub" "$d/authorized_keys"
  rm -f "$1/cidata.img"; truncate -s 4M "$1/cidata.img"
  mkfs.vfat -n CIDATA "$1/cidata.img" >/dev/null
  mcopy -i "$1/cidata.img" "$d"/* ::/
}

# Build under a staging name: only a finished install, cleanly shut down, becomes the base.
STAGE="$IMAGES/base.building"
rm -rf "$STAGE"; mkdir -p "$STAGE"
build_cidata "$STAGE"
qemu-img create -q -f qcow2 "$STAGE/disk.qcow2" "$DISK_SIZE"
cp "$OVMF_VARS_TEMPLATE" "$STAGE/vars.fd"

export LAB_SERIAL=1   # the wait below reads the firmware's serial output
log "installing $(basename "$ISO") unattended (about 10 minutes; screen: $STAGE/screen.png)"
start_vm "$STAGE" \
  -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0,readonly=on" -device ide-cd,drive=cdrom0,bootindex=2 \
  -drive "file=$STAGE/cidata.img,format=raw,if=none,id=cidata" -device usb-storage,drive=cidata
trap 'stop_vm "$STAGE"' EXIT

# The install reboots on its own into the installed system, which asks for the disk passphrase. The firmware names
# what it starts on the serial port, so wait for Limine on the disk before typing.
start=$SECONDS
until grep -aq 'starting Boot.*"Limine"' "$STAGE/serial.log" 2>/dev/null; do
  vm_running "$STAGE" || die "the VM stopped during the install (see $STAGE/serial.log, $STAGE/screen.png)"
  ((SECONDS - start < 2400)) || { screenshot "$STAGE" "$STAGE/screen.png"; die "install not finished after 40 minutes"; }
  if (((SECONDS - start) % 60 < 5)); then
    screenshot "$STAGE" "$STAGE/screen.png"; log "... installing ($((SECONDS - start))s)"
    # a failed install stops on its error screen and never reboots
    if tesseract "$STAGE/screen.png" - 2>/dev/null | grep -qi 'installation halted'; then
      trap - EXIT   # keep the VM for a look: root on tty2 has no password; the log is /var/log/omarchy-install.log
      die "the installer halted (screen: $STAGE/screen.png; the VM is still running)"
    fi
  fi
  sleep 5
done
log "install finished after $((SECONDS - start))s; first boot"
unlock_and_wait "$STAGE" 600
lab_ssh_root true || die "sudo with the lab password does not work"
log "installed system is up: $(lab_ssh 'cat /etc/os-release | grep ^PRETTY; uname -r')"
lab_ssh 'omarchy-version 2>/dev/null || true' | sed 's/^/[lab] omarchy /' >&2
stop_vm "$STAGE"; trap - EXIT
rm -rf "$STAGE/cidata" "$STAGE/cidata.img"   # it holds the disk passphrase in plain text

rm -rf "$BASE"; mv "$STAGE" "$BASE"
chmod -R a-w "$BASE/disk.qcow2" "$BASE/vars.fd"
log "base saved in $BASE; test/vm/reset.sh makes the working copy"
