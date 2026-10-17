---
title: "status --json"
labels: P2
---
**Goal:** an MDM can tell in one call whether a laptop's disk is protected the way it should be.

**Context:** fields like `encrypted`, `secure_boot` (enabled, own keys enrolled), `tpm_unlock` (enrolled, PCRs), `recovery_key` (present), `signed` (all boot files signed), `editor_locked`, each `true`/`false`/`unknown`; `schema` versioned as in monarchy-identity's status output. Read-only, works without root where possible.

**Done when:** implemented with unit tests against stubs, documented in `docs/reference/status-output.md` (user terms), and checked in the lab before and after `setup`.

**Depends on:** Skeleton.
