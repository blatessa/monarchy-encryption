---
title: "Design: fit into Omarchy's deferred provisioning and factory reset"
labels: P2
---
**Goal:** a fleet laptop goes from Omarchy's deferred-provisioning install to TPM unlock, a recovery key and directory sign-in without anyone typing a disk passphrase.

**Context:** Omarchy's first-boot `omarchy-provision-owner` re-keys LUKS from a throwaway keyfile to the owner's password; factory reset returns to that state (`docs/research.md`). A corporate flow wants TPM + recovery key (this project) and `monarchy-identity enroll` instead. Options: an Omarchy extension point (upstream proposal), or our own unit ordered around `omarchy-provision-owner.service`.

**Done when:** `docs/dev/architecture.md` describes the chosen flow, its failure modes, and what's needed from upstream (if anything), and follow-up implementation issues are filed. Design only.

**Depends on:** systemd initramfs spike (findings).
