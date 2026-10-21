# Status and limits

Version 0.2.0. **Tested in a virtual machine** (QEMU with UEFI firmware and a software TPM, Omarchy 4.0.5) and on one
laptop (an MSI, AMI firmware, set up and restarted with nothing typed). Try it on a spare laptop before a fleet.

## Works

- `setup`: the systemd boot environment, a locked boot menu, TPM unlock tied to this laptop's boot files, a recovery
  key, and the install passphrase removed, finished at a restart with nothing typed. Nothing changes in the firmware
  settings.
- Starting with nothing typed, snapshots from the boot menu included; the recovery key at the disk prompt when the
  boot files or the TPM changed, and `setup` re-tying the TPM afterwards.
- Kernel updates, Limine upgrades, `omarchy-refresh-limine` and Omarchy's migrations, with the laptop staying protected.
- `recovery-key` to replace the key, `status --json` for MDMs, `release` before Omarchy's factory reset.

## Limits

- **Omarchy's "install for a later owner" (deferred provisioning)** isn't supported: its first-boot setup re-keys the
  disk and removes the TPM and recovery key. `setup` refuses until first-boot setup is done; install fleet laptops
  unattended instead ([Roll out to a fleet](guides/rollout.md)).
- **Snapshots with an older boot image** (taken before a kernel update, or before `setup`) ask for the recovery key
  when started from the boot menu.
- **Root on the laptop can approve different boot files**, as updates do
  ([How it works](concepts/how-it-works.md#whats-checked-and-what-isnt)).
- **Hibernation** with TPM unlock resumes in the lab, but not reliably; the same happens without this tool.
