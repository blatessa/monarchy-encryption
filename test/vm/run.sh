#!/bin/bash
# Boot the lab VM (its disk, firmware variables and TPM state persist across runs) and wait until ssh answers.
#   test/vm/run.sh                    types the disk passphrase at the prompt (a stock install has no other way in)
#   test/vm/run.sh --no-passphrase    doesn't: the TPM must unlock the disk on its own
# Makes the working copy first if there isn't one. Stop it with test/vm/stop.sh; reach it with test/vm/ssh.sh.
source "$(dirname "$0")/lib.sh"

type_pw=1
case ${1:-} in --no-passphrase) type_pw=0 ;; "") ;; *) die "usage: $0 [--no-passphrase]" ;; esac
[[ -f $LAB/disk.qcow2 ]] || "$VM/reset.sh"
if vm_running "$LAB"; then log "already running"; else start_vm "$LAB"; fi
if ((type_pw)); then
  unlock_and_wait "$LAB" 300
else
  start=$SECONDS
  until lab_ssh true 2>/dev/null; do
    vm_running "$LAB" || die "the VM stopped while booting"
    ((SECONDS - start < 300)) || { screenshot "$LAB" "$LAB/boot-timeout.png"; die "no ssh after 300s without the passphrase (screen: $LAB/boot-timeout.png)"; }
    sleep 2
  done
fi
log "up: test/vm/ssh.sh (or ssh -i $KEY -p $SSH_PORT $LAB_USER@127.0.0.1)"
