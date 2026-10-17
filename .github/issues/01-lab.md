---
title: "Lab: QEMU VM with Secure Boot firmware and a software TPM"
labels: P0, needs-lab
---
**Goal:** a throwaway Omarchy VM where Secure Boot, TPM enrollment and initramfs changes can be tried, broken and reset in minutes. Nothing else can be verified without it.

**Context:** the host must never be used (AGENTS.md). Needs OVMF with Secure Boot variables in setup mode, `swtpm` as a TPM2, and an encrypted Omarchy install, ideally from the Quattro ISO so deferred provisioning and factory reset exist. monarchy-identity's `test/vm` (QEMU, OVMF, ssh key, `lab-check.sh`) is the pattern to copy.

**Done when:** `test/lab-check.sh` reports missing prerequisites with the fix; one command boots the VM with persistent firmware vars and TPM state; a second resets it to a clean encrypted install (snapshot of the disk image, vars and TPM state); ssh access works; `docs/dev/testing.md` describes it. Images, vars, TPM state and keys are git-ignored.

**Depends on:** nothing.
