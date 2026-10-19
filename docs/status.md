# Status and limits

Version 0.1.0. **Tested in a virtual machine only** (QEMU with Secure Boot firmware and a software TPM, Omarchy 4.0.5),
not yet on laptop hardware. Try it on a spare laptop before a fleet.

## Works

- `setup`: the systemd boot environment, Secure Boot with the laptop's own keys (Microsoft's kept for graphics cards
  and other devices), a locked boot menu, TPM unlock tied to Secure Boot, a recovery key, and the install passphrase
  removed.
- Starting with nothing typed; the recovery key at the disk prompt when Secure Boot is off or its keys changed, and
  `setup` re-tying the TPM afterwards.
- Kernel updates, Limine upgrades, `omarchy-refresh-limine` and Omarchy's migrations, with the laptop staying protected.
- `recovery-key` to replace the key, `status --json` for MDMs, `release` before Omarchy's factory reset.

## Limits

- **The restart between `setup`'s two runs needs the disk passphrase typed**, so a fleet rollout has one step at the
  laptop ([#37](https://github.com/blatessa/monarchy-encryption/issues/37)).
- **Omarchy's "install for a later owner" (deferred provisioning)** isn't supported: its first-boot setup re-keys the
  disk and removes the TPM and recovery key. `setup` refuses until first-boot setup is done; install fleet laptops
  unattended instead ([Roll out to a fleet](guides/rollout.md)).
- **Snapshots taken before `setup`** can't be started from the boot menu any more (their boot images aren't signed).
  They can still be restored from the running system, and snapshots taken afterwards start normally.
- **The TPM checks Secure Boot's state, not each boot file**: root on the laptop could sign a different boot image
  ([How it works](concepts/how-it-works.md#whats-checked-and-what-isnt)).
- **The firmware settings screen** can turn Secure Boot off unless it has a password: set one.
- **Hibernation** with TPM unlock resumes in the lab, but not reliably; the same happens without this tool.
