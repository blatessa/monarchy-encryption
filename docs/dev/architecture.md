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
   It ships as [`data/zz-monarchy-encryption.conf`](../../data/zz-monarchy-encryption.conf), and `setup` copies it in.
2. One line in `/etc/crypttab`: `root UUID=<luks uuid> none luks,x-initrd.attach` (`/etc/crypttab.initramfs` is
   deprecated in mkinitcpio 42). The name `root` keeps `/dev/mapper/root`, so `root=` and `resume=` stay valid.
3. Rebuild the UKI (`limine-update`, as part of the Secure Boot step, so it's built and signed once).

`setup` does all three (#18). Before changing anything, it checks that `/` really is on LUKS, and that any existing
`/etc/crypttab` line for the mapping opens the same volume, with no key file, in the initramfs (extra options are
fine). The boot files are rebuilt only when something changed, so running `setup` again changes nothing.

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
  not known. Keep counting hangs whenever the lab boots in a loop (`test/vm/boot-loop.sh N LABEL`). Update (#18): hangs
  like it happen on stock installs too, often at the first reboot after resuming from hibernation, so it looks like a
  lab problem; tracked in #21.
- Old snapshot entries keep the initramfs they were made with. A snapshot taken before the switch boots with the
  busybox initramfs, which can only ask for a passphrase or recovery key, not use the TPM. That's probably acceptable
  (snapshots are a recovery path, and a recovery key is a passphrase slot, so it should open the disk there; not yet
  tested), but `setup` should say so, and #6 or #7 should test it.
- Deferred provisioning embeds a keyfile in the UKI so the disk unlocks itself until first-boot setup (see
  research.md). Not checked here: whether that path still works with a systemd initramfs. It belongs to #9.

## Secure Boot with each laptop's own keys

**Decision:** `setup` creates Secure Boot keys on the laptop with `sbctl`, signs everything that boots, and enrolls
the keys (with Microsoft's alongside). Issue #4, October 2026, Omarchy 4.0.5 in the lab.

**One key set per laptop, not one per organisation.** The laptop re-signs its own boot image on every kernel update,
so its private signing key has to live on the laptop. With one organisation-wide key, one lost laptop would hold the key
every other laptop trusts. A per-laptop key lost with its laptop trusts nothing else. Nothing has to be distributed or
stored centrally.

**Microsoft's keys stay enrolled** (`sbctl enroll-keys --microsoft`): graphics cards and other devices run option ROMs
signed by Microsoft, and leaving them out can stop a laptop from showing anything at power-on. The cost is that
Microsoft-signed bootloaders (Windows, shim) still start. With the TPM bound to Secure Boot state (#5), booting one of
those should change what the TPM measures (PCR 7 records which certificate approved the loader), so the disk
wouldn't unlock. #5 should confirm that in the lab.

**Order: sign, check, then enroll.** Before the keys are in the firmware, unsigned files still start, so a failed or
interrupted `setup` leaves a laptop that boots. `setup` refuses before changing anything if the firmware holds someone
else's keys (not in setup mode, and the platform key isn't this laptop's). Running it again is safe.

**Signing rides on Limine's tools.** Once sbctl has keys, `limine-mkinitcpio-hook` signs what it writes: sbctl's
mkinitcpio hook signs each boot image before Limine records its hash, and `90-limine-enroll-config` signs Limine after
enrolling. `setup` runs `limine-update` and then checks with `sbctl verify` that Limine, the fallback and the boot
images are signed. Updates sign through the same path (tested with a kernel reinstall).

**The boot menu.** With the TPM unlocking the disk, changing the kernel command line at the menu (`init=/bin/sh`) would
be a root shell. Three things close it:

1. `editor_enabled: no` in `limine.conf`, which also removes the menu's "Blank Entry".
2. `ENABLE_ENROLL_LIMINE_CONFIG=yes` in `/etc/default/limine`: Limine's tools embed the checksum of `limine.conf`
   into the signed Limine binary, and Limine halts on a menu that doesn't match. The ESP isn't encrypted, so without
   this anyone with the laptop could edit the menu file directly. Limine's tools read this setting only from
   `/etc/default/limine`, never from a drop-in, so this one line is added to a file Omarchy's installer wrote
   (marked).
3. The firmware's fallback loader (`EFI/BOOT/BOOTX64.EFI`) becomes the enrolled Limine. Limine's tools copy a plain
   Limine there on every update, and choosing it from the firmware's boot menu would boot a changed menu. A Limine
   post hook, `/etc/boot/hooks/post.d/95-monarchy-encryption-fallback`, runs after their enroll hook and replaces it.

**Not covered here:**

- Snapshots taken before `setup` can't be started from the boot menu any more: their boot images are unsigned, and
  signing them would break the hash limine-snapper-sync pinned (findings.md). `setup` says how many there are. They
  can still be restored from the running system, and every snapshot taken afterwards starts. Fleet laptops run
  `setup` right after the install, before there are any snapshots. Making old ones bootable again is #19.
- `omarchy-refresh-limine` replaces `limine.conf` with Omarchy's default, so the editor comes back on. The checksum
  stays correct because it runs `limine-update`. Putting `editor_enabled: no` back belongs to `reassert` (#7).
- The firmware's own setup screen (F2, Del, or `S` in Limine's menu) can turn Secure Boot off unless it has a password.
  Software can't set one. With #5's policy, Secure Boot off means the TPM doesn't unlock the disk, so this isn't a way
  in, but a firmware password is still worth recommending.
- Anything that edits `limine.conf` without Limine's tools now stops the laptop from starting until the menu is
  re-enrolled. Omarchy's migrations in 4.0.5 only go through the tools. Factory reset is the exception (see #9).
