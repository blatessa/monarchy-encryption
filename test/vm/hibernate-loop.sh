#!/bin/bash
# Hibernate the lab VM N times and count how often it resumes (RAM contents back) rather than starting fresh. Each try
# starts from a fresh boot. Usage: hibernate-loop.sh N LABEL
source "$(dirname "$0")/lib.sh"
n=${1:-5} label=${2:-run} resumed=0 fresh=0
vm_running "$LAB" || { start_vm "$LAB"; unlock_and_wait "$LAB" 300; }
for i in $(seq "$n"); do
  lab_reboot "$LAB"
  id=$(lab_ssh 'cat /proc/sys/kernel/random/boot_id | tee /tmp/marker')
  up=$(lab_ssh 'cut -d" " -f1 /proc/uptime')
  lab_ssh_root systemctl hibernate >/dev/null 2>&1 || true
  for _ in $(seq 120); do vm_running "$LAB" || break; sleep 1; done
  vm_running "$LAB" && { log "$label try $i: still running 120s after hibernate"; qmp "$LAB" '"quit"' >/dev/null; sleep 2; }
  start_vm "$LAB"; unlock_and_wait "$LAB" 300
  if [[ $(lab_ssh 'cat /tmp/marker 2>/dev/null') == "$id" ]]; then resumed=$((resumed + 1)); r=resumed
  else fresh=$((fresh + 1)); r="STARTED FRESH ($(lab_ssh_root journalctl -b 0 -o cat -t systemd-hibernate-resume | tail -1))"; fi
  log "$label try $i (hibernated at ${up}s uptime): $r"
done
log "$label: $resumed resumed, $fresh started fresh, of $n"
