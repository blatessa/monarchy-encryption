# Architecture

Decisions and the reasons for them. Details and evidence are in [findings.md](findings.md).

## A systemd initramfs (sd-encrypt), not Clevis

**Decision:** switch Omarchy's busybox initramfs to a systemd one and unlock the disk with `systemd-cryptenroll`
(TPM2 now, recovery key alongside). Decided in spike #3, October 2026, on Omarchy 4.0.5 in the lab.

**Why not Clevis**, the alternative that keeps the busybox hooks: Clevis itself is in the Arch repositories, but its
mkinitcpio hook is not (`pacman -Si mkinitcpio-clevis-hook` finds nothing; it's packaged in the AUR), and this project
takes no AUR dependencies. Clevis would also add a second key-management system next to systemd's, which already
ships TPM2 enrollment, PCR policies and recovery keys (`systemd-cryptenroll --tpm2-device`, `--recovery-key`) in
packages Omarchy installs.

**What the switch is**, and nothing more:

1. `/etc/mkinitcpio.conf.d/zz-monarchy-encryption.conf`: sorts after Omarchy's drop-ins and maps their busybox hooks to
   the systemd ones (`udev`→`systemd`, `keymap`+`consolefont`→`sd-vconsole`, `encrypt`→`sd-encrypt`,
   `btrfs-overlayfs`→`sd-btrfs-overlayfs`, `resume` dropped). Mapping rather than replacing the list keeps whatever
   Omarchy decides about the rest (it drops `kms` on NVIDIA-only machines, and adds hooks over time). `sd-vconsole` is
   used only when Omarchy bundles `/etc/vconsole.conf`, so a non-Latin layout never makes the passphrase untypeable.
   The spike's version is [`test/vm/spike/zz-monarchy-encryption.conf`](../../test/vm/spike/zz-monarchy-encryption.conf).
2. One line in `/etc/crypttab`: `root UUID=<luks uuid> none luks,x-initrd.attach` (`/etc/crypttab.initramfs` is
   deprecated in mkinitcpio 42). The name `root` keeps `/dev/mapper/root`, so `root=` and `resume=` stay valid.
3. Rebuild the UKI (`limine-mkinitcpio`).

The kernel command line is **not** changed: `cryptdevice=` is ignored by a systemd initramfs, and Omarchy's first-boot
setup, factory reset and Quattro upgrade read it to find the LUKS partition. Nothing under `/usr/share/omarchy` or in
Omarchy's own `/etc` files is edited.

**Verified in the lab**, with the passphrase as the only key:

| | |
|---|---|
| Boots; disk opened by `systemd-cryptsetup@root` | yes, 15 of 15 boots in a row (about 24 s each, passphrase typed) |
| Omarchy's themed passphrase screen | yes (needs no serial console, see findings) |
| A snapper snapshot entry boots, writable | yes (`sd-btrfs-overlayfs`) |
| Hibernate, then resume after the passphrase | yes, RAM contents intact |
| `omarchy update` (packages, migrations, post-update hooks) | rebuilt UKI uses the systemd hooks |
| Kernel package reinstall, `omarchy-settings` reinstall (rewrites `omarchy_hooks.conf`), `omarchy-refresh-limine` | each rebuilt UKI uses the systemd hooks; the first boot after them hung once (below), every boot since works |

**Open:**

- One boot, the first after `omarchy-refresh-limine`, hung on a black screen before the root filesystem was mounted
  (nothing reached the journal). It didn't happen again in 15 reboots. Omarchy documents a similar intermittent hang
  on stock installs (the `systemd.tty.term.console=dumb` comment in `omarchy-defaults.conf`); whether this was that is
  not known. Keep counting hangs whenever the lab boots in a loop.
- Old snapshot entries keep the initramfs they were made with. A snapshot taken before the switch boots with the
  busybox initramfs, which can only ask for a passphrase or recovery key, not use the TPM. That's probably acceptable
  (snapshots are a recovery path, and a recovery key is a passphrase slot, so it should open the disk there; not yet
  tested), but `setup` should say so, and #6 or #7 should test it.
- Deferred provisioning embeds a keyfile in the UKI so the disk unlocks itself until first-boot setup (see
  research.md). Not checked here: whether that path still works with a systemd initramfs. It belongs to #9.
