# shared helpers. Sourced, not executed.
ME_ROOT="${ME_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ETC="${MONARCHY_ENCRYPTION_ETC:-/etc}"                            # overridable for tests, like the paths below
EFIVARS="${MONARCHY_ENCRYPTION_EFIVARS:-/sys/firmware/efi/efivars}"
SBCTL_DIR="${MONARCHY_ENCRYPTION_SBCTL_DIR:-/var/lib/sbctl}"       # sbctl's keys and GUID
TPM_DEVICE="${MONARCHY_ENCRYPTION_TPM:-/dev/tpmrm0}"
OMARCHY_PROVISIONING="${MONARCHY_ENCRYPTION_PROVISIONING:-/var/lib/omarchy/provisioning}"
EFI_GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c                     # vendor GUID of the UEFI spec's own variables

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
