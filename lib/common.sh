# shared helpers. Sourced, not executed.
ME_ROOT="${ME_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ETC="${MONARCHY_ENCRYPTION_ETC:-/etc}"   # overridable for tests

log() { echo "monarchy-encryption: $*" >&2; logger -t monarchy-encryption -- "$*" 2>/dev/null || true; }
die() { log "ERROR: $*"; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "this needs administrator rights: run it with sudo"; }
