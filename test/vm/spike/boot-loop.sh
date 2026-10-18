#!/bin/bash
# Spike #3: boot the lab VM N times (typing the passphrase) and count boots that never reach ssh. A hung boot is
# screenshotted and the VM restarted. Usage: boot-loop.sh N LABEL
source "$(dirname "$0")/../lib.sh"
n=${1:-10} label=${2:-run} ok=0 hung=0
out="$LAB/boot-loop-$label"; mkdir -p "$out"
vm_running "$LAB" || start_vm "$LAB"
for i in $(seq "$n"); do
  if lab_ssh true 2>/dev/null; then lab_ssh_root systemctl reboot >/dev/null 2>&1 || true; sleep 8; fi
  if (unlock_and_wait "$LAB" 120) 2>/dev/null; then
    ok=$((ok + 1)); log "$label boot $i: ok ($(lab_ssh 'systemd-analyze 2>/dev/null | head -1 | grep -o "= .*"'))"
  else
    hung=$((hung + 1)); screenshot "$LAB" "$out/hung-$i.png"; log "$label boot $i: HUNG (screen: $out/hung-$i.png)"
    qmp "$LAB" '"quit"' >/dev/null; sleep 2; start_vm "$LAB"
  fi
done
log "$label: $ok ok, $hung hung of $n"
