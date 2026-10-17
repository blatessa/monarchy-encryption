---
title: "Docs site: user guide and developer section"
labels: P3
---
**Goal:** the same documentation shape as monarchy-identity: a guide for administrators, internals under Development.

**Context:** copy identity's `mkdocs.yml`, `docs.yml` workflow and page structure (overview, getting started, how disk unlock works, recovery, CLI and status reference, status and limits, Development). User pages talk about disks, laptops and recovery keys; PCRs, keyslots and file paths go in `docs/dev/`.

**Done when:** `mkdocs build --strict` passes in CI, pages exist for what's implemented, and `docs/research.md` has moved under Development.

**Depends on:** Skeleton.
