---
title: "Skeleton: CLI, PKGBUILD, CI and the fast test layer"
labels: P0
---
**Goal:** the empty shape every later issue fills in, so feature work never has to invent structure.

**Context:** mirror monarchy-identity: `bin/monarchy-encryption` dispatching `setup | status [--json] | recovery-key | reassert`, `lib/common.sh` (logging, root check, `/etc` path overrides for tests), `packaging/PKGBUILD` (depends `sbctl`, `tpm2-tss`, `systemd`, `cryptsetup`; no AUR), CI running shellcheck, unit tests and `makepkg` (copy `.github/workflows/ci.yml` from identity). Unit tests run commands against a temp root with stub `cryptsetup`, `sbctl`, `systemd-cryptenroll`, `bootctl` on `PATH`.

**Done when:** every command exists and prints "not implemented" with exit 1, `--help` works, the package builds, CI is green on a PR, and one example unit test shows the stub pattern. `docs/dev/testing.md` explains the two test layers.

**Depends on:** nothing.
