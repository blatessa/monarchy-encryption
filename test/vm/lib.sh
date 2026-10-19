# Shared lab helpers: paths, the VM's firmware/TPM/disk, QMP keystrokes, ssh. Sourced by the test/vm scripts.
# The lab is an encrypted Omarchy install under QEMU with Secure Boot firmware (in setup mode: no keys yet) and a
# software TPM. `images/base/` is the clean install and never changes after test/vm/install.sh; `images/lab/` is the
# working copy (a disk overlay plus its own copies of the firmware variables and TPM state), which reset.sh recreates.
set -euo pipefail

VM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES="$VM/images"
BASE="$IMAGES/base"
LAB="$IMAGES/lab"
KEY="$VM/keys/id_lab"
ISO_VERSION="${LAB_ISO_VERSION:-4.0.5}"
ISO="$IMAGES/omarchy-$ISO_VERSION.iso"

LAB_USER=lab
LAB_PASSWORD=monarchy   # also the disk passphrase. No 'e' or 'b': early keystrokes can land in Limine's menu
LAB_HOSTNAME=monarchy-lab
SSH_PORT="${LAB_SSH_PORT:-2223}"   # monarchy-identity's lab uses 2222
MEMORY="${LAB_MEMORY:-8192}"
DISK_SIZE=40G

OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd   # needs SMM; its variables start empty, i.e. setup mode
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
    -name monarchy-lab -cpu host -enable-kvm -machine q35,smm=on,accel=kvm -smp 4 -m "$MEMORY" \
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
