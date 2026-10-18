#!/bin/bash
# Download the Omarchy release ISO the lab installs from (6 GB) and check it against its published SHA-256.
source "$(dirname "$0")/lib.sh"

[[ -f $ISO ]] && { log "already have $ISO"; exit 0; }
url="https://iso.omarchy.org/omarchy-$ISO_VERSION.iso"
mkdir -p "$IMAGES"
want=$(curl -fsSL "$url.sha256" | awk '{print $1}')
[[ $want =~ ^[0-9a-f]{64}$ ]] || die "no checksum at $url.sha256"
curl -fL --retry 3 -o "$ISO.part" "$url"
echo "$want  $ISO.part" | sha256sum -c --quiet || die "checksum mismatch: $ISO.part is corrupt; delete it and retry"
mv "$ISO.part" "$ISO"
log "saved $ISO"
