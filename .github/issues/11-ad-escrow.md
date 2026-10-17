---
title: "Decide: recovery key escrow in Active Directory"
labels: P3
---
**Goal:** decide whether this tool should offer to store recovery keys in the laptop's AD computer object, as BitLocker does, or leave escrow entirely to the caller.

**Context:** AD has `msFVE-RecoveryInformation` objects for BitLocker. Writing there needs the machine's credentials from monarchy-identity's join, which couples the two packages. The default stance is "the caller stores it" (AGENTS.md scope).

**Done when:** the decision and reasoning are in `docs/dev/architecture.md`; if yes, an implementation issue is filed.

**Depends on:** Recovery key.
