# shared helpers. Sourced, not executed.
ME_ROOT="${ME_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ETC="${MONARCHY_ENCRYPTION_ETC:-/etc}"                            # overridable for tests, like the paths below
EFIVARS="${MONARCHY_ENCRYPTION_EFIVARS:-/sys/firmware/efi/efivars}"
TPM_DEVICE="${MONARCHY_ENCRYPTION_TPM:-/dev/tpmrm0}"
OMARCHY_PROVISIONING="${MONARCHY_ENCRYPTION_PROVISIONING:-/var/lib/omarchy/provisioning}"
PCRLOCK="${MONARCHY_ENCRYPTION_PCRLOCK:-/usr/lib/systemd/systemd-pcrlock}"
PCRLOCK_DIR="${MONARCHY_ENCRYPTION_PCRLOCK_DIR:-/var/lib/pcrlock.d}"   # where pcrlock reads boot file descriptions
PCRLOCK_LIB="${MONARCHY_ENCRYPTION_PCRLOCK_LIB:-/usr/lib/pcrlock.d}"     # and systemd's own
POLICY_FILE="${MONARCHY_ENCRYPTION_POLICY:-/var/lib/systemd/pcrlock.json}"   # pcrlock's record of the TPM policy
STATE="${MONARCHY_ENCRYPTION_STATE:-/var/lib/monarchy-encryption}"    # the policy's recovery PIN; which files it covers
RUN_DIR="${MONARCHY_ENCRYPTION_RUN:-/run/monarchy-encryption}"         # this start only

log() { echo "monarchy-encryption: $*" >&2; logger -t monarchy-encryption -- "$*" 2>/dev/null || true; }
die() { log "ERROR: $*"; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "this needs administrator rights: run it with sudo"; }

# Files and lines we write carry this marker.
ME_MARK="# managed by monarchy-encryption"

# The ESP, where Limine and the boot images live: what Limine's tools are told (ESP_PATH in /etc/default/limine).
esp_path() {
  local p=""
  [[ -r $ETC/default/limine ]] && p=$(sed -n 's/^ESP_PATH=["'\'']\{0,1\}\([^"'\'']*\).*/\1/p' "$ETC/default/limine" | tail -n 1)
  printf '%s\n' "${MONARCHY_ENCRYPTION_ESP:-${p:-/boot}}"
}
