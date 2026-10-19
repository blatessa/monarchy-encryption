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
- `omarchy-refresh-limine` replaces `limine.conf` with Omarchy's default, so the editor comes back on: handled by the
  editor hook (below, "Staying correct across updates").
- The firmware's own setup screen (F2, Del, or `S` in Limine's menu) can turn Secure Boot off unless it has a password.
  Software can't set one. With #5's policy, Secure Boot off means the TPM doesn't unlock the disk, so this isn't a way
  in, but a firmware password is still worth recommending.
- Anything that edits `limine.conf` without Limine's tools now stops the laptop from starting until the menu is
  re-enrolled. Omarchy's migrations in 4.0.5 only go through the tools. Factory reset is the exception (see #9).

## The recovery key

**Decision:** `recovery-key` adds a key with `systemd-cryptenroll --recovery-key`, proves it opens the disk, hands it
to the caller, and only then removes the previous recovery key. Issue #6, October 2026, systemd 262 in the lab.

**What unlocks the change.** Adding a keyslot needs a key the disk already opens with. Decided by the owner: the TPM
once #5 has enrolled it (`--unlock-tpm2-device=auto`, so an MDM needs no secret), and otherwise, or when the TPM
refuses, the disk passphrase or the current recovery key, asked for on a terminal or read as one line from stdin. It
reaches `systemd-cryptenroll` through a pipe (`--unlock-key-file=/dev/stdin`), never a file or the environment.
Rejected: adding the slot with the volume key of the open disk (`cryptsetup luksAddKey --volume-key-file`), which
needs no secret at all but bypasses `systemd-cryptenroll`, so the slot would carry no `systemd-recovery` token.

**Order: add, prove, hand over, remove.** The new key is tested on its own slot (`cryptsetup open --test-passphrase
--key-slot=N`). If it doesn't open the disk, its slot is removed and the old key stays. The key is printed before the
old slot is removed, so a failed removal can't lose the only copy of the new key; the caller is told
(`"previous_key": "not_removed"`) and the command still succeeds. Only recovery slots are removed: the passphrase and
the TPM slot are never touched here (removing the passphrase belongs to #5, behind the same proof).

**Where it goes.** stdout only: the key alone on a line, or `{"schema":1,"recovery_key":…,"previous_key":
"none"|"removed"|"not_removed"}` with `--json`. Explanations go to stderr, the log says only "recovery key created" or
"replaced". Storing it is the caller's job. `setup` creates one in its first run (below).

## TPM unlock

**Decision:** the TPM opens the disk at boot, bound to **PCR 7** only. `setup` gets there in **two runs** with a
restart between, and removes the installer's passphrase once the TPM and the recovery key each open the disk. Issue
#5, October 2026, systemd 262 and swtpm in the lab. The three choices were the owner's.

**PCR 7 only.** It records the Secure Boot state: whether it's on, and which keys are enrolled (PK, KEK, db, dbx).
Kernel and Omarchy updates don't change it, so nothing has to be re-enrolled after one (tested). Secure Boot off,
another platform key, or a changed db all change it, and the disk asks for the recovery key (tested). Since only boot
files signed with this laptop's key start, and the menu can't be edited (above), PCR 7 stands for "this laptop's
signed software". What it doesn't catch: a boot image this laptop signed itself with a changed command line or
initramfs, which needs root on the laptop first. Binding to the measured boot image too (a signed PCR 11 policy) would
close that, at the cost of producing a signed policy on every boot image rebuild through Limine's tools: a later issue.

**Two runs.** Secure Boot takes effect at the next start, and PCR 7 is measured by the firmware at boot, so
enrolling in the same run that enrolls the keys would bind the disk to "Secure Boot off". Predicting the value
(systemd-pcrlock) was rejected: a wrong guess on some firmware is a laptop that never unlocks by itself.

1. First run (Secure Boot not on yet): the systemd initramfs, Secure Boot, then a recovery key, made **last** so the
   output that carries it is the final one (`setup --json`: `{"done": false, "recovery_key": "…"}`). It ends with
   "restart, then run setup again".
2. Second run (started with Secure Boot on and this laptop's keys): enrolls the TPM (`--tpm2-device=auto
   --tpm2-pcrs=7`), and proves it opens the disk through the same token the initramfs uses (`cryptsetup open
   --test-passphrase --token-only --token-type systemd-tpm2`). No change to `/etc/crypttab`: systemd-cryptsetup tries
   the TPM token by itself.

Both runs read the recovery key or passphrase (terminal, or one line on stdin) and check it opens the disk **before
anything is changed**. A finished laptop needs no input at all: `setup` then changes nothing.

**The passphrase goes, by default,** only in a run unlocked with the **recovery key**: that proves the recovery key
opens the disk and that the caller has it. A second run given the passphrase enrolls the TPM, keeps the passphrase,
and says how to finish (an MDM just sends the key it got from the first run). The TPM is proven before the passphrase
slots are wiped and again after. Only keyslots with no token are wiped: the installer's passphrase, or one added with
`cryptsetup`.

**A TPM slot that no longer matches** (a firmware update, or the keys changed) leaves the disk asking at boot. Running
`setup` again with the recovery key enrolls the TPM afresh: the new slot is enrolled and proven first, then the stale
one is removed. A new enrollment that doesn't open the disk is removed again.

## Staying correct across updates

**Decision:** two hooks, and a `reassert` command that needs no key. Issue #7, October 2026, Omarchy 4.0.5 in the lab.

What can undo `setup` was found by trying it on a laptop that's fully set up (findings.md, "Updates after setup"):
kernel updates and Omarchy's migrations stay correct on their own; a limine upgrade leaves Limine unsigned (Omarchy's
`99-omarchy-limine` pacman hook); `omarchy-refresh-limine` brings the boot menu editor back.

1. **A Limine post hook, `/etc/boot/hooks/post.d/85-monarchy-encryption-editor`**, linked by `setup` next to the
   fallback hook. Limine's tools run it before their own `90-limine-enroll-config` whenever they rewrite the menu, so
   the editor is locked *before* the checksum is enrolled. There is no moment when an enrolled menu has an editor,
   and nothing has to notice the change afterwards.
2. **A pacman hook, `zz-monarchy-encryption.hook`**, sorted after every Limine and Omarchy hook. It runs `reassert`
   after transactions that touch the kernel, initramfs hooks, firmware, systemd, cryptsetup, Limine, mkinitcpio,
   sbctl, Omarchy's packages or this one. Upgrading this package therefore also brings laptops set up by an older
   version up to date (new hooks get linked).
3. **`reassert`** runs `setup`'s parts that need no key and no question: the initramfs drop-in and crypttab line,
   the menu settings, both Limine hooks, and a rebuild and re-sign when anything isn't signed and protected. It never
   touches Secure Boot keys, keyslots or the TPM. A TPM that no longer opens the disk (a firmware update) is reported,
   since re-enrolling needs the recovery key (`setup`). Before `setup` it does nothing.

**No Omarchy post-update hook** (monarchy-identity has one). `omarchy update` installs packages through pacman, so the
pacman hook runs, and its migrations rebuild through Limine's tools, so the editor hook runs. Nothing it does is left
for a post-update hook to catch.

**No watcher on the ESP.** A path unit or timer could catch changes made outside Limine's tools and pacman, but the
project takes no such machinery, and the cases found all go through one of the two.

## Provisioning and factory reset

**Decision:** fleet laptops come from a **full unattended install**, not Omarchy's deferred provisioning, until Omarchy
offers the hooks below. `setup` refuses while provisioning is pending (#30). A factory reset starts by handing the
firmware back (#31). Issue #9 (design only), October 2026, Omarchy 4.0.5; evidence in findings.md, "Omarchy's
provisioning and factory reset".

**The flow that works today** (README, "Setting up a laptop"):

1. Unattended install with a disk passphrase the MDM generates for this laptop, separate from the user's password.
2. `setup` with that passphrase on stdin; the MDM stores the recovery key it returns. Restart.
3. `setup` with the recovery key: TPM unlock, the passphrase removed.
4. `monarchy-identity enroll`: directory sign-in.

No step needs a person at the laptop, and no lasting secret crosses the MDM channel except the recovery key, which
the MDM is meant to hold.

**Why not deferred provisioning yet.** Omarchy's deferred install exists for exactly this hand-off, but its pieces
assume it owns the disk's keys:

| Omarchy does | What it does to a set-up laptop |
|---|---|
| Unlocks the provisioning window with `cryptkey=` and a key file in the initramfs | The systemd initramfs ignores `cryptkey=`: after `setup`'s first run the disk asks for a throwaway passphrase nobody knows (tested). |
| First-boot re-key: add the owner's password, kill every other slot | Removes the TPM and recovery slots; the owner's password becomes the disk passphrase again (the consumer model this project replaces). |
| Asks the owner on tty1 for a local account | A fleet laptop's people sign in with their directory account (monarchy-identity). |

Ordering our own unit around `omarchy-provision-owner.service` doesn't fix these: before it, the disk can't be
handed a TPM slot that survives the re-key; after it, the throwaway key is gone and the disk passphrase is the
owner's, which the MDM doesn't know. And a run at first boot has nobody to hand the recovery key to: it must reach
the MDM, never the disk. What would make it work is upstream (#32): a systemd-compatible auto-unlock (a key file in
`/etc/crypttab`, or `rd.luks.key=`), a re-key that removes only the slot it staged, and a hook after user creation
where `setup` and `monarchy-identity enroll` run with the staged key file as their secret.

**Factory reset.** `omarchy-system-factory-reset` rebuilds the boot files from the install-time `@factory` snapshot,
which has none of this laptop's keys, so they come out unsigned and, with the laptop's keys in the firmware, it
doesn't start. Signing them inside the reset would put this laptop's private key into the snapshot handed to the
next owner. Rejected. Instead, the reset gives the firmware back first: `sbctl reset` removes the platform key from
the running laptop (tested), the firmware returns to setup mode, and the reset's boot files should then start with Secure Boot
off (the full reset is #31's to test). The keyslots need no step of ours: the reset adds its throwaway key (the recovery key answers its passphrase
question) and provisioning's re-key removes the rest. After the reset, `setup` starts over. A pre-reset hook upstream
(#32) would make the hand-back automatic.

**Failure modes, and what each leaves:**

- `setup` run while provisioning is pending: a disk that asks for a passphrase nobody knows; the recovery key opens
  it. Prevented by #30.
- Factory reset without the hand-back: a laptop the firmware won't start. Fix: clear Secure Boot keys (or turn Secure
  Boot off) in the firmware settings; it then starts with the reset's unsigned files.
- Provisioning's re-key on a set-up laptop (a reset after the hand-back, as designed): the TPM and recovery slots are
  gone and the owner's password opens the disk. Expected; `setup` takes it back.
