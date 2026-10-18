#!/bin/bash
# The fast layer: every unit suite, no lab, no root. Prints one line per suite; exit 1 if any failed.
cd "$(dirname "$0")" || exit 1
rc=0
for s in *.sh; do
  [[ $s == lib.sh || $s == run.sh ]] && continue
  start=$(date +%s%N); out=$(bash "$s" 2>&1); r=$?
  if ((r == 0)) && ! grep -q '^  FAIL\|^FAIL' <<<"$out"; then st=PASS; else st=FAIL; rc=1; grep -E 'FAIL|SKIP|^      ' <<<"$out" | head -15; fi
  printf '%-4s %-16s %sms\n' $st "$s" "$(( ($(date +%s%N)-start)/1000000 ))"
done
exit $rc
