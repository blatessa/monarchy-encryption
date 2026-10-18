#!/bin/bash
# Build the package from this checkout (CI, the lab, trying a change) rather than the release tarball the PKGBUILD names:
# packs the working tree under that tarball's name, which makepkg then uses instead of downloading. Extra arguments go
# to makepkg.
set -euo pipefail
P="$(cd "$(dirname "$0")" && pwd)"; R="$(cd "$P/.." && pwd)"
v=$(sed -n 's/^pkgver=//p' "$P/PKGBUILD"); t="monarchy-encryption-$v.tar.gz"
tar -C "$R" --exclude=./.git --exclude=./test --exclude=./packaging/src --exclude=./packaging/pkg \
  --exclude="./packaging/$t" --exclude='*.pkg.tar.*' --transform "s,^\.,monarchy-encryption-$v," -czf "$P/$t" .
cd "$P" && makepkg -f --skipchecksums "$@"
