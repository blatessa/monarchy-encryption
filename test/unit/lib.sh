# Harness for the fast layer: the real CLI against a temp /etc with stub commands first on PATH, as root inside a
# user namespace (`unshare -r`). No VM, no real root. Source it: `source "$(dirname "$0")/lib.sh"`.
# Stubs live in stubs/ (their behaviour and where it was observed: docs/dev/findings.md). Every suite ends with `result`.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUBS="$REPO/test/unit/stubs"
MEBIN="$REPO/bin/monarchy-encryption"
fail=0
ok()  { printf '  PASS %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
check() { local desc=$1; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }   # check DESC CMD...
result() { ((fail)) && { echo "RESULT: FAIL"; exit 1; }; echo "RESULT: ALL PASS"; }
unshare -r true 2>/dev/null || { echo "SKIP: 'unshare -r' is not allowed here (user namespaces disabled)"; exit 1; }

# sandbox: an empty machine in a temp dir; suites add the files they need under $T/etc.
sandbox() {
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  export MONARCHY_ENCRYPTION_ETC="$T/etc" MONARCHY_ENCRYPTION_ROOT="$REPO" HOME="$T/home"
  export STUB_STATE="$T/state" STUB_LOG="$T/calls.log" PATH="$STUBS:$PATH"
  mkdir -p "$T/etc" "$T/state" "$T/home"
  : > "$STUB_LOG"
}

# me ARGS...: run the CLI as (fake) root; sets OUT (stdout+stderr) and RC.
me() { OUT=$(unshare -r "$MEBIN" "$@" 2>&1 </dev/null); RC=$?; }
# me_user ARGS...: same, without root (the real uid).
me_user() { OUT=$("$MEBIN" "$@" 2>&1 </dev/null); RC=$?; }
called() { grep -qF -- "$1" "$STUB_LOG"; }   # did a stub see this command line?
