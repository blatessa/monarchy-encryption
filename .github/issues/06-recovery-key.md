---
title: "Recovery key: create, rotate, hand off"
labels: P1
---
**Goal:** every laptop has a recovery key that opens its disk, and the caller (a person or an MDM) gets it exactly once.

**Context:** `systemd-cryptenroll --recovery-key` generates a strong typeable key in its own keyslot. The key is printed once (and in `--json` for an MDM); it is never written to the laptop's disk or logs. `recovery-key` rotates it: add the new slot, prove it opens the volume, then remove the old one. Storing it is the caller's job (escrow to AD is a separate, later issue).

**Done when:** `monarchy-encryption recovery-key [--json]` works with unit tests (stubs) and a lab test showing the key opens the volume and the old one no longer does after rotation; the user docs explain where the key goes and how to use it at the boot prompt.

**Depends on:** Skeleton (lab part also needs Lab).
