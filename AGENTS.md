# AGENTS.md

Guidance for coding agents (and humans) working in this repo. Keep it short and accurate; update it when reality changes.

## What this is
`monarchy-encryption` makes an Omarchy (Arch + Hyprland, Limine, LUKS on btrfs) laptop unlock its disk with the TPM,
protected by Secure Boot with the organisation's own keys, plus a per-laptop recovery key. It's a single-purpose
utility like [monarchy-identity](https://github.com/blatessa/monarchy-identity): called by a person or an MDM, not a
platform. Status: the empty CLI and the fast test layer exist; no feature works yet. Read `docs/research.md` before
anything else; `docs/dev/testing.md` for how to test.

## Hard rules
- **Never test on the host machine.** A bad initramfs, Secure Boot or keyslot change can make a disk unbootable or
  unrecoverable. Everything runs in the QEMU lab (OVMF with Secure Boot + swtpm), built by issue "Lab".
- **Never remove the last way into a disk.** Before removing a passphrase or keyslot, prove that another keyslot
  (recovery key or TPM) opens the volume (`cryptsetup open --test-passphrase`). This is correctness, not an undo feature.
- **Never write a recovery key to the laptop's disk** or logs. It's printed once, to the caller.
- Never edit `/usr/share/omarchy/` (package-owned, overwritten by `omarchy update`). Use `/etc` drop-ins that sort
  after Omarchy's (for example `/etc/mkinitcpio.conf.d/zz-monarchy-encryption.conf`).
- No AUR dependencies. `sbctl`, `tpm2-tss` and systemd's `systemd-cryptenroll` are in the Arch repositories.
- Don't publish, tag, force-push or change repo settings without the owner asking.

## Scope
In: Secure Boot keys and signing, the systemd initramfs needed for TPM unlock, TPM enrollment and its PCR policy,
recovery keys, locking the boot-entry editor, staying correct across updates, `status --json`.
Out: sign-in and autologin (monarchy-identity), storing keys (the caller's job), device management (the MDM). No
undo machinery (timers, backups, rollback). Test: would it belong in a plain "TPM disk unlock" tool?

## Conventions (same as monarchy-identity)
- Bash with `set -euo pipefail`; quote everything; python3 only where bash is unreasonable.
- **Defaults over configuration.** The user is an administrator, not a maintainer: good behaviour is the default.
  Name things in their terms (disk, laptop, recovery key); keep PCRs, keyslots and file paths in `docs/dev/`.
- User docs are a guide; internals go in `docs/dev/` and only when they explain a decision or a trap.
- Tests: fast layer first (scripts against a temp root with stubbed `cryptsetup`, `sbctl`, `systemd-cryptenroll`,
  `bootctl`), lab only for what needs real firmware, TPM or initramfs. Suites must not depend on order.
- A non-obvious lesson goes into `docs/dev/findings.md` (create it with the first one).
- Small, focused commits; explain why. Branch from `main`, open a PR, let CI run.

## Picking work
GitHub issues are the work queue for agents. Labels: `P0` (blocks everything else) to `P3` (polish). Assume work needs
the lab unless the issue says otherwise. Take the highest-priority open issue whose dependencies (listed in its body)
are closed and that has no assignee or open PR. Each issue says what done looks like. Close it from the PR (`Fixes #N`). Found new work?
Open an issue in the same shape instead of growing the current change.

## Definition of done
- Unit tests pass; anything touching boot, keys or the initramfs passes in the lab, including a reboot.
- The volume can still be opened by a remaining keyslot after every change (tested).
- Anything the CLI uses is installed by the PKGBUILD (once it exists).
- Docs considered: say in the PR what changed for users ("docs: none, internal" is fine when true).
