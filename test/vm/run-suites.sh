#!/bin/bash
# Run lab suites side by side, each in a VM of its own (images/lab-SUITE, ssh on its own port), and print what passed.
#   test/vm/run-suites.sh [-j N] [SUITE...]    SUITE: tpm, updates, ... (test/vm/e2e-SUITE.sh); all of them by default
# Builds the package once. -j: how many VMs at once (default: what fits in free memory, LAB_MEMORY each, at most 4).
# Logs: images/logs/SUITE.log. A suite's VM is stopped when it ends; its files stay until the next run, for debugging.
source "$(dirname "$0")/lib.sh"

export LAB_MEMORY="${LAB_MEMORY:-4096}"
parallel=""
[[ ${1:-} == -j ]] && { parallel=$2; shift 2; }
suites=("$@")
((${#suites[@]})) || for f in "$VM"/e2e-*.sh; do f=${f##*/e2e-}; suites+=("${f%.sh}"); done
for s in "${suites[@]}"; do [[ -f $VM/e2e-$s.sh ]] || die "no suite $s (test/vm/e2e-$s.sh)"; done
if [[ -z $parallel ]]; then
  parallel=$(( $(awk '/MemAvailable/ {print $2}' /proc/meminfo) / 1024 / (LAB_MEMORY + 1024) ))
  ((parallel > 4)) && parallel=4; ((parallel < 1)) && parallel=1
fi

"$VM/../../packaging/build-local.sh" --nodeps --noconfirm >/dev/null 2>&1 || die "package build failed (run packaging/build-local.sh)"
LAB_PKG=$(ls -t "$VM"/../../packaging/monarchy-encryption-*.pkg.tar.zst | head -1); export LAB_PKG
logs="$IMAGES/logs"; mkdir -p "$logs"
log "${#suites[@]} suite(s), $parallel at a time, ${LAB_MEMORY} MB each; logs in $logs"

# run SUITE PORT: one suite in its own VM; "SUITE PASS|FAIL SECONDS" in logs/SUITE.result
run() {
  local start=$SECONDS rc=0
  LAB_NAME="lab-$1" LAB_SSH_PORT=$2 bash "$VM/e2e-$1.sh" >"$logs/$1.log" 2>&1 </dev/null || rc=$?
  LAB_NAME="lab-$1" LAB_SSH_PORT=$2 bash -c "source '$VM/lib.sh'; stop_vm \"\$LAB\"" >/dev/null 2>&1 || true
  printf '%s %s %ss\n' "$1" "$( ((rc)) && echo FAIL || echo PASS )" $((SECONDS - start)) >"$logs/$1.result"
}

start=$SECONDS i=0
for s in "${suites[@]}"; do
  while (($(jobs -rp | wc -l) >= parallel)); do wait -n || true; done
  rm -f "$logs/$s.result"
  run "$s" $((2230 + i)) &
  i=$((i + 1))
done
wait

fail=0
for s in "${suites[@]}"; do
  read -r name verdict took < <(cat "$logs/$s.result" 2>/dev/null || echo "$s FAIL ?")
  printf '  %-4s %-14s %6s  %s\n' "$verdict" "$name" "$took" "$logs/$s.log"
  [[ $verdict == PASS ]] || { fail=1; { grep -h '  FAIL' "$logs/$s.log" || tail -n 3 "$logs/$s.log"; } | sed 's/^/        /'; }
done
log "done in $((SECONDS - start))s"
((fail)) && { echo "RESULT: FAIL"; exit 1; }; echo "RESULT: ALL PASS"
