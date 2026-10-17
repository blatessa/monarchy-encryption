# Research: what Omarchy provides

Gathered October 2026 on Omarchy 4.0.4 (read-only inspection of `/usr/share/omarchy`, `/etc` and the boot state of a
real install), plus community guides. Upstream Omarchy has no official TPM or Secure Boot support yet. Verify against
the Omarchy version you're on: it moves fast.

## Omarchy's model

- **One password for everything.** The installer's password is "used for user + root, and disk encryption"
  (`install/provisioning/setup-form.sh`).
- **The disk prompt is the sign-in.** First-boot setup keeps autologin on for encrypted installs because "the LUKS prompt
  is the auth boundary" (`bin/omarchy-provision-owner`). monarchy-identity turns autologin off when a laptop joins a
  directory; that's the gap this project closes.
- `omarchy-drive-password` changes a LUKS passphrase (argon2id). There's no TPM, FIDO2 or recovery-key tooling for the
  disk (`omarchy-setup-security-fido2` is for sudo/polkit only).

## Boot chain

| Piece | State on a stock install |
|---|---|
| Bootloader | Limine, with `limine-mkinitcpio` building UKIs (`ENABLE_UKI=yes`, `CUSTOM_UKI_NAME="omarchy"`, settings in `/etc/limine-entry-tool.d/omarchy-defaults.conf`). Snapper snapshot entries in the menu (`limine-snapper-sync`). |
| Initramfs | **busybox** hooks: `base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs` (`/etc/mkinitcpio.conf.d/omarchy_hooks.conf`, which also adjusts `kms` and `vconsole.conf` and is edited by migrations). |
| Disk | `cryptdevice=PARTUUID=…:root` on the command line, `root=/dev/mapper/root`, swapfile hibernation via `resume=/dev/mapper/root resume_offset=…`. |
| Measurement | `bootctl status`: Measured UKI yes, Measured OS yes; TPM2 present (`/dev/tpmrm0`). |
| Secure Boot | Disabled, firmware in setup mode. `sbctl` not installed. |
| Tools present | `systemd-cryptenroll`, `tpm2-tss`. |

**Consequence:** `systemd-cryptenroll --tpm2-device` unlock needs a systemd-based initramfs (`systemd` + `sd-encrypt`
hooks, `/etc/crypttab.initramfs`), not the busybox `encrypt` hook. A community guide reports that without
`crypttab.initramfs` the boot hangs with no prompt. Clevis is the alternative that keeps the busybox hook.

## Deferred provisioning and factory reset (the natural integration point)

Omarchy's Quattro installer can install a machine **with no user yet**:

- The disk gets a throwaway passphrase, and a keyfile is embedded in the UKI so it unlocks itself during provisioning
  (`/var/lib/omarchy/provisioning/luks-key`).
- On first boot, `omarchy-provision-owner.service` (tty1, before SDDM) asks for the owner, creates the account, then
  `rekey_luks` adds the owner's password, kills every other slot and rebuilds the UKI without the keyfile.
- `omarchy-system-factory-reset` returns a machine to that state (root swapped for the `@factory` snapshot, LUKS re-keyed
  to a throwaway passphrase, provisioning pending).

A fleet flow wants the same shape with a different ending: install → first boot → **TPM + recovery key** (this
project) and **directory enrollment** (monarchy-identity) instead of "re-key to the owner's password". How to hook in
(an Omarchy extension point, or our own unit ordered around theirs) is an open question.

## Known traps

- **Boot-entry editing.** If the TPM unlocks the disk and Limine lets someone edit the kernel command line, they can boot
  to a root shell on an unlocked disk. The editor must be off, and the config protected.
- **PCR choice.** PCR 7 (Secure Boot state) survives kernel updates but is only meaningful with Secure Boot on and the
  organisation's own keys enrolled. Firmware updates can change it; the recovery key covers that. Binding to measured
  UKIs (PCR 11 with a signed policy) is stronger but more moving parts.
- **Re-signing.** Every kernel/UKI rebuild (updates, `omarchy-refresh-limine`, Omarchy migrations that rebuild the UKI)
  must be re-signed, or the next boot fails Secure Boot.
- **Omarchy migrations** rewrite `omarchy_hooks.conf`; our hook changes must survive them (drop-in that sorts after it).
- **Untested with a systemd initramfs:** the `btrfs-overlayfs` hook (snapshot boot), Plymouth's themed prompt, keymap
  bundling (`sd-vconsole`), and hibernate resume.
- Some firmware (American Megatrends, Apple) is called out by Omarchy as unsafe for custom EFI entries
  (`omarchy-setup-direct-boot`); expect similar firmware quirks with key enrollment.

## Sources

- Omarchy 4.0.4: `bin/omarchy-provision-owner`, `bin/omarchy-system-factory-reset`, `bin/omarchy-drive-password`,
  `bin/omarchy-setup-direct-boot`, `install/provisioning/`, `/etc/mkinitcpio.conf.d/omarchy_hooks.conf`,
  `/etc/limine-entry-tool.d/omarchy-defaults.conf`.
- [Secure Boot + TPM2 Auto-Unlock on Omarchy 4.0.x (gist)](https://gist.github.com/jan-zezula/56233fb66301aff5a822e25f70f24bf6)
- [omarchy-headless-boot](https://github.com/nickcisne/omarchy-headless-boot) (TPM2 + PCR 7, passphrase kept as fallback)
- [Custom Secure Boot keys guide, Discussion #2296](https://github.com/omacom/omarchy/discussions/2296)
- [Clevis with TPM2 on Omarchy, Discussion #1283](https://github.com/omacom/omarchy/discussions/1283)
- [Enable secure boot on Omarchy](https://acrogenesis.com/enable-secure-boot-on-omarchy/)
