# Shared lab helpers: paths, the VM's firmware/TPM/disk, QMP keystrokes, ssh. Sourced by the test/vm scripts.
# The lab is an encrypted Omarchy install under QEMU with UEFI firmware (Secure Boot off, no keys: setup leaves the
# firmware's keys alone, so their absence changes nothing) and a software TPM. `images/base/` is the clean install and never changes after test/vm/install.sh; `images/lab/` is the
# working copy (a disk overlay plus its own copies of the firmware variables and TPM state), which reset.sh recreates.
# LAB_NAME and LAB_SSH_PORT give a VM of its own (images/$LAB_NAME), so suites can run side by side (run-suites.sh).
set -euo pipefail

VM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES="$VM/images"
BASE="$IMAGES/base"
LAB_NAME="${LAB_NAME:-lab}"
LAB="$IMAGES/$LAB_NAME"
KEY="$VM/keys/id_lab"
ISO_VERSION="${LAB_ISO_VERSION:-4.0.5}"
ISO="$IMAGES/omarchy-$ISO_VERSION.iso"

LAB_USER=lab
LAB_PASSWORD=monarchy   # also the disk passphrase. No 'e' or 'b': early keystrokes can land in Limine's menu
LAB_HOSTNAME=monarchy-lab
SSH_PORT="${LAB_SSH_PORT:-2223}"   # monarchy-identity's lab uses 2222
MEMORY="${LAB_MEMORY:-8192}"
DISK_SIZE=40G

OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd   # needs SMM; its variables start empty (no keys, Secure Boot off)
OVMF_VARS_TEMPLATE=/usr/share/edk2/x64/OVMF_VARS.4m.fd

log() { printf '[lab] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# --- QEMU ---------------------------------------------------------------------------------------
vm_running() { [[ -f $1/qemu.pid ]] && kill -0 "$(cat "$1/qemu.pid")" 2>/dev/null; }   # vm_running DIR

qmp() { # qmp DIR JSON-COMMAND: one QMP command against the VM in DIR
  printf '{"execute":"qmp_capabilities"}\n{"execute":%s}\n' "$2" |
    timeout 5 socat -t 2 - "UNIX-CONNECT:$1/qmp.sock" 2>/dev/null || true
}

press() { # press DIR KEYS: one chord in QEMU qcode names, like ret or shift-a
  local part json="" parts
  IFS='-' read -ra parts <<<"$2"
  for part in "${parts[@]}"; do json+="{\"type\":\"qcode\",\"data\":\"$part\"},"; done
  qmp "$1" "\"send-key\", \"arguments\": {\"keys\": [${json%,}]}" >/dev/null
}

type_text() { # type_text DIR TEXT (letters, digits and a few symbols)
  local ch i
  for ((i = 0; i < ${#2}; i++)); do
    ch=${2:i:1}
    case $ch in
      [a-z0-9]) press "$1" "$ch" ;;
      [A-Z]) press "$1" "shift-${ch,,}" ;;
      -) press "$1" minus ;;
      .) press "$1" dot ;;
      " ") press "$1" spc ;;
      *) die "type_text: unsupported character '$ch'" ;;
    esac
    sleep 0.05
  done
}

screenshot() { # screenshot DIR FILE.png: what the VM's screen shows now
  qmp "$1" "\"screendump\", \"arguments\": {\"filename\": \"$1/screen.ppm\"}" >/dev/null
  [[ -s $1/screen.ppm ]] && magick "$1/screen.ppm" "$2" 2>/dev/null; rm -f "$1/screen.ppm"
}

# start_vm DIR [EXTRA QEMU ARGS]: boots DIR/disk.qcow2 with DIR/vars.fd and the TPM state in DIR/tpm, in the background.
# swtpm runs alongside and exits with QEMU (--terminate). No serial port unless LAB_SERIAL=1 (then DIR/serial.log): the
# firmware would list it as a console, the UKI stub would add console= for it, and Plymouth would then show a plain-text
# disk prompt instead of Omarchy's themed one (docs/dev/findings.md). A laptop has none.
start_vm() {
  local dir=$1; shift
  vm_running "$dir" && die "the VM in $dir is already running"
  mkdir -p "$dir/tpm"
  rm -f "$dir/swtpm.sock" "$dir/qmp.sock"
  swtpm socket --tpm2 --tpmstate "dir=$dir/tpm" --ctrl "type=unixio,path=$dir/swtpm.sock" \
    --log "file=$dir/swtpm.log" --pid "file=$dir/swtpm.pid" --terminate --daemon
  for _ in $(seq 50); do [[ -S $dir/swtpm.sock ]] && break; sleep 0.1; done
  local serial=(-serial none)
  [[ -n ${LAB_SERIAL:-} ]] && serial=(-serial "file:$dir/serial.log")
  qemu-system-x86_64 \
    -name "monarchy-$LAB_NAME" -cpu host -enable-kvm -machine q35,smm=on,accel=kvm -smp 4 -m "$MEMORY" \
    -global driver=cfi.pflash01,property=secure,value=on -global ICH9-LPC.disable_s3=1 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$dir/vars.fd" \
    -chardev socket,id=chrtpm,path="$dir/swtpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0 \
    -drive file="$dir/disk.qcow2",format=qcow2,if=none,id=drive0 -device virtio-blk-pci,drive=drive0,bootindex=1 \
    -device virtio-vga -display none -usb -device usb-tablet \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 -device virtio-net-pci,netdev=net0 \
    -qmp "unix:$dir/qmp.sock,server,nowait" "${serial[@]}" -pidfile "$dir/qemu.pid" -daemonize \
    "$@"
}

stop_vm() { # stop_vm DIR: clean poweroff, then harder ways
  local dir=$1 i
  vm_running "$dir" || return 0
  lab_ssh_root systemctl poweroff >/dev/null 2>&1 || qmp "$dir" '"system_powerdown"' >/dev/null
  for i in $(seq 60); do vm_running "$dir" || return 0; sleep 1; done
  log "no clean shutdown after 60s; stopping QEMU"
  qmp "$dir" '"quit"' >/dev/null; sleep 2
  vm_running "$dir" && kill "$(cat "$dir/qemu.pid")"
  return 0
}

# --- the guest ----------------------------------------------------------------------------------
lab_ssh() {
  ssh -i "$KEY" -p "$SSH_PORT" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR "$LAB_USER@127.0.0.1" "$@"
}
# root_with SECRET CMD: CMD (a remote shell command) as root with SECRET on stdin, no newline after it. Secrets go
# this way, never in a command line: sudo logs command lines to the journal (findings.md).
root_with() { printf '%s\n%s' "$LAB_PASSWORD" "$1" | lab_ssh "sudo -S -p '' $2"; }
lab_ssh_root() { lab_ssh "echo $LAB_PASSWORD | sudo -S -p '' $(printf '%q ' "$@")"; }   # lab_ssh_root CMD ARGS...

# unlock_and_wait DIR TIMEOUT [KEY]: types the disk passphrase (or KEY) on an interval until ssh answers. Plymouth's
# prompt can't be read reliably, and keystrokes that arrive before it are discarded. The passphrase has no Limine menu
# keys in it; a recovery key may (e, b), so type one only after setup has locked the menu editor.
unlock_and_wait() {
  local dir=$1 timeout=$2 key=${3:-$LAB_PASSWORD} start=$SECONDS next=10
  until lab_ssh true 2>/dev/null; do
    vm_running "$dir" || die "the VM stopped while booting"
    if ((SECONDS - start >= timeout)); then
      screenshot "$dir" "$dir/boot-timeout.png"; die "no ssh after ${timeout}s (screen: $dir/boot-timeout.png)"
    fi
    if ((SECONDS - start >= next)); then type_text "$dir" "$key"; press "$dir" ret; ((next += 20)); fi
    sleep 2
  done
}

# lab_reboot DIR [KEY]: restart the VM and wait for the *new* boot (typing the passphrase, or KEY). The old system can
# still answer ssh for a while after `systemctl reboot`, so waiting for ssh alone can land on the one shutting down.
lab_reboot() {
  local old i; old=$(lab_ssh cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  lab_ssh_root systemctl reboot >/dev/null 2>&1 || true
  for i in $(seq 60); do lab_ssh true 2>/dev/null || break; sleep 1; done
  unlock_and_wait "$1" 300 "${2:-}"
  [[ $(lab_ssh cat /proc/sys/kernel/random/boot_id) != "$old" ]] || die "the VM didn't restart"
}

# up_untyped SECONDS: the VM answers ssh within SECONDS with nothing typed (the TPM opened the disk)
up_untyped() { local start=$SECONDS; until lab_ssh true 2>/dev/null; do ((SECONDS - start < $1)) || return 1; sleep 2; done; }
# restart_untyped: restart and let the TPM open the disk; 1 if it's still waiting at the prompt after 120 s
restart_untyped() {
  local old; old=$(lab_ssh cat /proc/sys/kernel/random/boot_id)
  lab_ssh_root systemctl reboot >/dev/null 2>&1 || true
  for _ in $(seq 60); do lab_ssh true 2>/dev/null || break; sleep 1; done
  up_untyped 120 && [[ $(lab_ssh cat /proc/sys/kernel/random/boot_id) != "$old" ]]
}

# --- checkpoints ----------------------------------------------------------------------------------
# A checkpoint is the lab VM's disk overlay, firmware variables and TPM state, saved after a clean shutdown, so a suite
# can start from a precondition ("set up") instead of a clean install, and debugging can retry from just before a
# failure. One built with this checkout's package is keyed to the package's files and the function that built it, and
# rebuilt when either changes. Lab-only values it needs (the recovery key its build made, what to type at the disk
# prompt) are kept with it under images/ (git-ignored). Only preconditions belong in one, never what a suite tests.
CHECKPOINTS="$IMAGES/checkpoints"
CHECKPOINT_VARS=()   # set by a checkpoint's build; empty for one saved by hand
package_hash() { (cd "$VM/../.." && cat bin/* lib/* hooks/* data/* packaging/PKGBUILD packaging/*.hook packaging/*.service 2>/dev/null) | sha256sum | cut -c1-16; }

# checkpoint_unlock UNLOCK: start the stopped lab VM and wait for ssh; UNLOCK is "tpm" (type nothing) or what to type
checkpoint_unlock() {
  start_vm "$LAB"
  if [[ $1 == tpm ]]; then up_untyped 180 || die "the VM didn't start with nothing typed"; else unlock_and_wait "$LAB" 300 "$1"; fi
}
# checkpoint_save NAME UNLOCK [ID [nostart]]: save the running lab VM as NAME (shut down cleanly, copied, started again
# unless nostart), with the variables named in CHECKPOINT_VARS
checkpoint_save() {
  local dir="$CHECKPOINTS/$1"
  stop_vm "$LAB"; rm -rf "$dir"; mkdir -p "$dir"
  cp --reflink=auto "$LAB/disk.qcow2" "$LAB/vars.fd" "$dir/"; cp -r --reflink=auto "$LAB/tpm" "$dir/tpm"
  : > "$dir/vars"; ((${#CHECKPOINT_VARS[@]})) && declare -p "${CHECKPOINT_VARS[@]}" | sed 's/^declare /declare -g /' > "$dir/vars"
  echo "$2" > "$dir/unlock"; echo "${3:-manual}" > "$dir/id"
  log "saved checkpoint $1"
  [[ ${4:-} == nostart ]] || checkpoint_unlock "$2"
}
# checkpoint_copy NAME: the lab VM's files (stopped) and variables set to checkpoint NAME's
checkpoint_copy() {
  local dir="$CHECKPOINTS/$1"
  [[ -f $dir/disk.qcow2 ]] || die "no checkpoint $1"
  stop_vm "$LAB"; rm -rf "$LAB"; mkdir -p "$LAB"
  cp --reflink=auto "$dir/disk.qcow2" "$dir/vars.fd" "$LAB/"; cp -r --reflink=auto "$dir/tpm" "$LAB/tpm"
  source "$dir/vars"
}
# checkpoint_restore NAME: the lab VM back in state NAME, running, its variables set
checkpoint_restore() { checkpoint_copy "$1"; checkpoint_unlock "$(<"$CHECKPOINTS/$1/unlock")"; log "restored checkpoint $1"; }
# checkpoint NAME BUILD: leave the lab VM running in state NAME. BUILD (a function) gets there from anything (a clean
# install, or another checkpoint) and sets CHECKPOINT_UNLOCK and the variables named in CHECKPOINT_VARS. Restored
# instead of built while the package and BUILD are what they were when it was saved. Suites running side by side
# take turns: the first builds it, the others wait and restore it.
checkpoint() {
  local id fd; id=$( { package_hash; declare -f "$2"; } | sha256sum | cut -c1-16)
  mkdir -p "$CHECKPOINTS"; exec {fd}>"$CHECKPOINTS/$1.lock"; flock "$fd"
  if [[ -f $CHECKPOINTS/$1/id && $(<"$CHECKPOINTS/$1/id") == "$id" ]]; then
    checkpoint_copy "$1"; exec {fd}>&-; checkpoint_unlock "$(<"$CHECKPOINTS/$1/unlock")"; log "restored checkpoint $1"; return
  fi
  log "building checkpoint $1"
  CHECKPOINT_VARS=() CHECKPOINT_UNLOCK=""
  "$2"
  checkpoint_save "$1" "$CHECKPOINT_UNLOCK" "$id" nostart; exec {fd}>&-
  checkpoint_unlock "$CHECKPOINT_UNLOCK"
}

# Where most suites start: a clean install with this checkout's package installed.
build_installed() {
  "$VM/reset.sh"; "$VM/run.sh" >/dev/null
  "$VM/install-package.sh"
  CHECKPOINT_UNLOCK=$LAB_PASSWORD
}

# finished: the boot service finished setup at the start after it (the one-time unlock is gone); 1 after 120 s
finished() {
  local i; for i in $(seq 60); do
    [[ $(lab_ssh_root monarchy-encryption status --json 2>/dev/null | jq -r .disk.one_time_unlock) == false ]] && return 0; sleep 2
  done; return 1
}

# The precondition most suites after setup want: a clean install set up by this checkout's package, restarted so it
# finished (TPM unlock, no passphrase). Sets RECOVERY_KEY.
build_set_up() {
  checkpoint installed build_installed
  RECOVERY_KEY=$(root_with "$LAB_PASSWORD" "monarchy-encryption setup --json 2>/dev/null" | jq -r .recovery_key)
  restart_untyped || die "the restart after setup waited at the disk prompt"
  finished && [[ $(lab_ssh_root monarchy-encryption status --json | jq -r .protected) == true ]] || die "setup didn't finish"
  CHECKPOINT_VARS=(RECOVERY_KEY) CHECKPOINT_UNLOCK=tpm
}
