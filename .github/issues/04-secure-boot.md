---
title: "Secure Boot with the organisation's own keys"
labels: P1, needs-lab
---
**Goal:** `setup` puts the laptop on Secure Boot with its own keys, everything that boots is signed, and the boot menu can't be used to bypass it.

**Context:** `sbctl create-keys`, `sbctl enroll-keys -m` (keep Microsoft keys for option ROMs), sign Limine's EFI binary and the UKIs `limine-mkinitcpio` builds. Lock Limine's entry editor and protect its config (otherwise a TPM-unlocked disk is a root shell away; see research). Firmware must be in setup mode; detect and explain when it isn't. Fleet keys (one set per org vs per laptop) is a decision to record.

**Done when:** in the lab, `monarchy-encryption setup` (this part) leaves Secure Boot enabled and booting, an unsigned EFI binary is refused, the editor can't change the command line, and `status --json` reports it. Unit tests cover the command sequence with stubs.

**Depends on:** Lab, Skeleton.
