---
title: "Stay correct across updates"
labels: P2, needs-lab
---
**Goal:** kernel, Limine and Omarchy updates never leave the laptop unbootable or silently unprotected.

**Context:** every UKI rebuild must be re-signed (sbctl ships a pacman hook; check it covers `limine-mkinitcpio` output and `omarchy-refresh-limine`). Omarchy migrations may rewrite `omarchy_hooks.conf` or the Limine defaults; our drop-ins must still apply. `reassert` re-checks and repairs, run from a pacman hook (same pattern as monarchy-identity).

**Done when:** in the lab, a kernel update, `omarchy-refresh-limine` and a simulated migration each leave the VM booting with TPM unlock, and `status --json` flags anything unsigned or missing.

**Depends on:** Secure Boot, TPM unlock.
