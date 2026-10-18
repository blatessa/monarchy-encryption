#!/bin/bash
# Throw the lab VM away and start again from the clean install: a new disk overlay on images/base/disk.qcow2, and
# fresh copies of its firmware variables (Secure Boot back in setup mode) and TPM state. Takes seconds.
source "$(dirname "$0")/lib.sh"

[[ -f $BASE/disk.qcow2 && -f $BASE/vars.fd && -d $BASE/tpm ]] || die "no base install: run test/vm/install.sh"
stop_vm "$LAB"
rm -rf "$LAB"; mkdir -p "$LAB"
qemu-img create -q -f qcow2 -b "$BASE/disk.qcow2" -F qcow2 "$LAB/disk.qcow2"
cp "$BASE/vars.fd" "$LAB/vars.fd"; chmod u+w "$LAB/vars.fd"
cp -r "$BASE/tpm" "$LAB/tpm"
log "lab reset to the clean install"
