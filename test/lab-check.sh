#!/bin/bash
# Check the lab prerequisites and state; prints the exact next command for anything missing. Exit 0 = the lab VM is up.
cd "$(dirname "$0")/.." || exit 1
source test/vm/lib.sh
set +e
rc=0
ok() { printf '  ok      %s\n' "$1"; }
no() { printf '  MISSING %s\n          -> %s\n' "$1" "$2"; rc=1; }
for c in qemu-system-x86_64:qemu-full qemu-img:qemu-full swtpm:swtpm socat:socat ssh:openssh curl:curl jq:jq \
  openssl:openssl mkfs.vfat:dosfstools mcopy:mtools magick:imagemagick tesseract:tesseract; do
  command -v "${c%%:*}" >/dev/null && ok "${c%%:*}" || no "${c%%:*}" "sudo pacman -S --needed ${c#*:}"
done
[[ -w /dev/kvm ]] && ok "/dev/kvm usable" || no "/dev/kvm" "enable virtualization in the firmware and add yourself to the kvm group"
[[ -f $OVMF_CODE && -f $OVMF_VARS_TEMPLATE ]] && ok "OVMF with Secure Boot" || no "OVMF with Secure Boot" "sudo pacman -S --needed edk2-ovmf"
[[ -f $ISO ]] && ok "Omarchy $ISO_VERSION ISO" || no "Omarchy $ISO_VERSION ISO" "test/vm/fetch-iso.sh"
[[ -f $BASE/disk.qcow2 ]] && ok "clean install (images/base)" || no "clean install (images/base)" "test/vm/install.sh (about 10 minutes)"
[[ -f $LAB/disk.qcow2 ]] && ok "working copy (images/lab)" || no "working copy (images/lab)" "test/vm/reset.sh"
if lab_ssh true 2>/dev/null; then ok "lab VM reachable on 127.0.0.1:$SSH_PORT"
else no "lab VM not running" "test/vm/run.sh"; fi
((rc == 0)) && echo "lab ready" || echo "lab NOT ready"
exit $rc
