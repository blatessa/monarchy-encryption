#!/bin/bash
# Build the package from this checkout and install it in the running lab VM, with its dependencies from the
# repositories (as pacman would on a laptop). LAB_PKG: a package already built (run-suites.sh builds it once).
source "$(dirname "$0")/lib.sh"
pkg=${LAB_PKG:-}
if [[ -z $pkg ]]; then
  ( flock 9; "$VM/../../packaging/build-local.sh" --nodeps --noconfirm >/dev/null 2>&1 ) 9>"$IMAGES/build.lock" ||
    die "package build failed (run packaging/build-local.sh)"
  pkg=$(ls -t "$VM"/../../packaging/monarchy-encryption-*.pkg.tar.zst | head -1)
fi
lab_ssh 'cat > /tmp/monarchy-encryption.pkg.tar.zst' < "$pkg"
# Omarchy's update guard only stops a direct system upgrade; this is an install
lab_ssh_root env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Sy --noconfirm --needed >/dev/null 2>&1 || true
lab_ssh_root env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -U --noconfirm /tmp/monarchy-encryption.pkg.tar.zst >/dev/null \
  || die "pacman -U failed in the VM"
log "installed $(basename "$pkg")"
