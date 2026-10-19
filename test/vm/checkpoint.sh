#!/bin/bash
# Save and restore lab VM states by hand, for debugging: retry from just before a failure instead of from a clean
# install. Suites use checkpoint() in lib.sh, which also rebuilds a checkpoint when the package changes; these don't.
#   test/vm/checkpoint.sh save NAME [UNLOCK]   the running VM as NAME; UNLOCK: what to type at the disk prompt
#                                              (default: the lab passphrase), or "tpm" when the TPM unlocks it
#   test/vm/checkpoint.sh restore NAME         the VM back in state NAME, running
#   test/vm/checkpoint.sh list | clear
source "$(dirname "$0")/lib.sh"
case ${1:-} in
  save) [[ -n ${2:-} ]] || die "usage: $0 save NAME [UNLOCK]"; checkpoint_save "$2" "${3:-$LAB_PASSWORD}" ;;
  restore) [[ -n ${2:-} ]] || die "usage: $0 restore NAME"; checkpoint_restore "$2" ;;
  list) for d in "$CHECKPOINTS"/*/; do [[ -d $d ]] && printf '%-24s %s  %s\n' "$(basename "$d")" "$(<"$d/id")" "$(date -r "$d/id" '+%F %R')"; done ;;
  clear) rm -rf "$CHECKPOINTS"; log "checkpoints removed" ;;
  *) die "usage: $0 save NAME [UNLOCK] | restore NAME | list | clear" ;;
esac
