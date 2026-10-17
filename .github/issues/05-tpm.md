---
title: "TPM unlock bound to Secure Boot state"
labels: P1, needs-lab
---
**Goal:** the disk unlocks on its own at boot on this laptop, only when it booted the organisation's signed software.

**Context:** `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7` after the initramfs switch and Secure Boot. Decide (and record) the PCR policy: PCR 7 alone survives kernel updates; signed PCR 11 policies are stronger. The original passphrase: keep, or remove once the recovery key exists (policy default to decide; never remove the last other keyslot).

**Done when:** in the lab the VM boots to the login screen with no disk prompt; with Secure Boot off, or a changed key database, it falls back to a prompt (recovery key or passphrase); a kernel update still unlocks; the test proves another keyslot still opens the volume.

**Depends on:** systemd initramfs spike, Secure Boot, Recovery key.
