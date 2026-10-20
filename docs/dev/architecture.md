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
   It ships as [`data/zz-monarchy-encryption.conf`](https://github.com/blatessa/monarchy-encryption/blob/main/data/zz-monarchy-encryption.conf), and `setup` copies it in.
2. One line in `/etc/crypttab`: `root UUID=<luks uuid> none luks,x-initrd.attach` (`/etc/crypttab.initramfs` is
   deprecated in mkinitcpio 42). The name `root` keeps `/dev/mapper/root`, so `root=` and `resume=` stay valid.
3. Rebuild the UKI (`limine-update`, together with the boot menu step, so it's built once).

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

## Measured boot, not Secure Boot ownership

**Decision:** the TPM opens the disk only for the boot files this laptop measured: a systemd-pcrlock policy over
**PCR 4** (Limine, which carries the menu's checksum, and the boot image) and **PCR 11** (the boot image's sections, as
its stub measured them), kept in a TPM NV index. The firmware's Secure Boot keys are left as they are. Issue #26,
October 2026, systemd 262 in the lab and a read-only check on an MSI laptop. Replaced owning Secure Boot with each
laptop's own keys (#4, #5), the owner's call.

**Why not Secure Boot.** Enrolling the laptop's own keys needs the firmware in setup mode. Laptops ship with the
manufacturer's platform key enrolled (an MSI: "MSI SHIP PK", immutable from the OS), and clearing it is a visit to
the firmware settings, on every laptop. A fleet can't do that; the lab, which starts in setup mode, never showed it.
Measured boot needs nothing from the firmware but a TPM 2.0 with PolicyAuthorizeNV.

**PCR 4 and 11.** The firmware measures every EFI program it starts into PCR 4: Limine, then the boot image Limine
chainloads. Limine carries the b2sum of `limine.conf` (ENABLE_ENROLL_LIMINE_CONFIG), and the menu holds the boot
image's hash and its command line, so PCR 4 covers the command line too. PCR 11 holds the boot image's sections
(kernel, initramfs, command line) as systemd-stub measured them. Rejected:

| PCR | Why not |
|---|---|
| 7 (Secure Boot state) | With Secure Boot off it adds nothing an attacker can't reproduce, and a dbx update would leave the laptop asking for the recovery key. |
| 5 (GPT, boot variables) | Unpredictable: OVMF measured an Exit Boot Services retry. |
| 9, 12 | pcrlock's own credential ("Global credentials initrd") is measured there, after the policy is made. |
| 0-3 | The firmware itself: every firmware update would need the recovery key. |

**What it doesn't catch.** Root on the laptop can approve different boot files (that's how updates work), as before.
Another operating system, a live USB, a different Limine or boot image, or a changed menu don't get the key.

**The policy follows updates through Limine's tools.** Every rebuild (a kernel update, a snapshot, which changes the
menu and so Limine, `omarchy-refresh-limine`) runs Limine's post hooks. `96-monarchy-encryption-policy`, after the
fallback hook, describes the new files (`lock-pe` for Limine, `lock-uki` for each boot image) as the variant
"current", and rewrites the policy to allow "booted" (the files that started) or "current". The boot service
(`monarchy-encryption boot`, at every start) replaces both with the files that just started. So at most two sets are
allowed, and an update never leaves the running start unrecognised. `reassert` rewrites the policy when it no longer
covers the files on the ESP (a change behind Limine's tools). Each rewrite is serialised with `flock`
(limine-snapper-sync runs the hooks twice within a second).

**Our own recovery PIN.** pcrlock's default recovery PIN is sealed behind the policy itself, so once a start misses
the policy (the disk prompt, typed recovery key), the policy can never be rewritten (`Esys_PolicyOR` 0x1c4). `setup`
makes a PIN of its own (`/var/lib/monarchy-encryption/pin`, root only, on the encrypted disk) and passes it as `$PIN`
with `--recovery-pin=query`. It unlocks rewriting the policy, not the disk. Not in `/root`: limine-snapper-sync runs
the hooks with `ProtectHome=yes`.

**Refusing up front.** `setup` checks, before changing anything, that the TPM can hold the policy (`is-supported`) and
that pcrlock recognises everything the firmware measured into PCR 4 and 11 at this start (`predict --strict` with the
files on the ESP). A stock laptop starts with the busybox initramfs, which measures nothing, so systemd's own
initramfs components (`750-enter-initrd`, `750-os-separator`) are left out when the first try fails: a match without
them means they are absent, not unrecognised. Firmware that measures something pcrlock doesn't know is refused, not
left asking for the recovery key at every start.

**The boot menu.** With the TPM unlocking the disk, changing the kernel command line at the menu (`init=/bin/sh`) would
be a root shell. Three things close it:

1. `editor_enabled: no` in `limine.conf`, which also removes the menu's "Blank Entry".
2. `ENABLE_ENROLL_LIMINE_CONFIG=yes` in `/etc/default/limine`: Limine's tools embed the checksum of `limine.conf`
   into the Limine binary, and Limine halts on a menu that doesn't match. The ESP isn't encrypted, so without this
   anyone with the laptop could edit the menu file directly. Limine's tools read this setting only from
   `/etc/default/limine`, never from a drop-in, so this one line is added to a file Omarchy's installer wrote
   (marked). Limine is in PCR 4, so a menu changed and re-enrolled by someone else is a different Limine too.
3. The firmware's fallback loader (`EFI/BOOT/BOOTX64.EFI`) becomes the enrolled Limine. Limine's tools copy a plain
   Limine there on every update, and choosing it from the firmware's boot menu would boot a changed menu. A Limine
   post hook, `/etc/boot/hooks/post.d/95-monarchy-encryption-fallback`, runs after their enroll hook and replaces it.

**Not covered here:**

- `omarchy-refresh-limine` replaces `limine.conf` with Omarchy's default, so the editor comes back on: handled by the
  editor hook (below, "Staying correct across updates").
- Anything that edits `limine.conf` without Limine's tools stops the laptop from starting until the menu is
  re-enrolled. Omarchy's migrations in 4.0.5 only go through the tools.

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
"replaced". Storing it is the caller's job. `setup` creates one (below).

## TPM unlock

**Decision:** the TPM opens the disk at boot through the measured-boot policy (above). `setup` gets there in **one
run and a restart** with nothing typed, and removes the installer's passphrase once the TPM opens the disk and the
recovery key has been handed over. Issue #5, October 2026, systemd 262 and swtpm in the lab; the restart with nothing
typed: #37; the policy: #26. The choices were the owner's.

**The keyslot points at the policy, not at PCR values.** `systemd-cryptenroll --tpm2-pcrlock=/var/lib/systemd/pcrlock.json`
binds the slot to the NV index (`tpm2_pcrlock: true`, `tpm2-pcrs: []`), so an update rewrites the policy and never
touches the disk's keyslots. pcrlock also writes `/boot/loader/credentials/pcrlock.<machine-id>.cred`, which
systemd-stub passes to the initramfs (works with Limine), so it can unlock before `/var` is mounted.

**A restart.** The policy describes what the firmware measured at a start, and a stock laptop's start has the busybox
initramfs: the policy can only be made once the laptop starts with the systemd initramfs `setup` puts in.

1. `setup`: the checks above, the systemd initramfs, the boot menu, a **one-time unlock** (below), then a recovery
   key, made **last** so the output that carries it is the final one (`setup --json`: `{"done": false,
   "recovery_key": "…"}`). It links `monarchy-encryption-boot.service` into `multi-user.target.wants` and ends with
   "restart".
2. At the restart, the service runs `boot`: it makes the policy from the files that started, enrolls the TPM
   (unlocked by the one-time unlock), proves it opens the disk through the same token the initramfs uses
   (`cryptsetup open --test-passphrase --token-only --token-id=N`), removes the passphrase, then the one-time unlock.
   At every later start, `boot` only pins the policy to the files that started. No change to `/etc/crypttab`:
   systemd-cryptsetup tries the TPM tokens by itself.

**The one-time unlock** is a TPM slot bound to nothing (`--tpm2-pcrs= --tpm2-pcrlock=`: without the second,
`systemd-cryptenroll` picks up `pcrlock.json` by itself), so the restart needs nobody at the keyboard (#37). Until that
start, anyone holding the laptop can start it and get in: one start with the disk effectively unencrypted, the same
exposure as Omarchy's own provisioning window. Chosen over the alternatives:

| Option | Why not |
|---|---|
| Predict the policy for that start from the new boot files | The busybox start's record says nothing about the systemd initramfs; a wrong guess is a passphrase prompt, which is the problem being solved. |
| A key file in the boot image (Omarchy's provisioning) | The same exposure, but the key sits in plain text on the ESP: readable from the disk alone, and it can outlive its deletion on flash. The TPM's secret never leaves the TPM, and the disk alone stays locked. |
| A person types the passphrase at the restart (0.1.0) | No unattended rollout. |

`boot` removes the one-time unlock **whatever happens** (an EXIT trap): the policy or the TPM enrolment failing leaves
the passphrase and the recovery key, and the disk asks from the next start. Not leaving it is the point: a laptop that
never finishes would otherwise open by itself indefinitely. `status` reports it (`disk.one_time_unlock`, part of
`protected`), and `setup` run by hand after the restart does the same as `boot`. TPM tokens are told apart by what
they're bound to: `tpm_enrolled` and `tpm_unlocks` look only at tokens bound to the policy or to PCRs, the one-time
unlock is the one bound to neither.

`setup` reads the recovery key or passphrase (terminal, or one line on stdin) and checks it opens the disk **before
anything is changed**. `boot` needs none: the one-time unlock opens the disk. A finished laptop needs no input at all:
`setup` then changes nothing.

**The passphrase goes** once the TPM opens the disk and the recovery key has been handed over. Printing it counts as
handing it over (the owner's call, #37): an MDM sends it to its endpoint, a person stores it; asking the caller to
send it back would cost a step, and the unattended restart is the point. The one-time unlock is the evidence: it's
there only after `setup` printed the key (or one existed before). Without a recovery key, `boot` keeps the
passphrase. Run by hand, `setup` removes the passphrase only when given the recovery key; given the passphrase, it
keeps it and says how to finish. The TPM is proven before the passphrase slots are wiped and again after. Only
keyslots with no token are wiped: the installer's passphrase, or one added with `cryptsetup`. `boot` never creates a
recovery key: its output goes to the journal, and there's nobody to hand it to.

**A TPM slot that no longer matches** (a firmware update, or the keys changed) leaves the disk asking at boot. Running
`setup` again with the recovery key enrolls the TPM afresh: the new slot is enrolled and proven first, then the stale
one is removed. A new enrollment that doesn't open the disk is removed again.

## Staying correct across updates

**Decision:** two hooks, and a `reassert` command that needs no key. Issue #7, October 2026, Omarchy 4.0.5 in the lab.

What can undo `setup` was found by trying it on a laptop that's fully set up (findings.md, "Updates after setup"):
kernel updates and Omarchy's migrations stay correct on their own; a limine upgrade leaves a plain Limine with no
enrolled menu checksum (Omarchy's `99-omarchy-limine` pacman hook); `omarchy-refresh-limine` brings the boot menu
editor back. Every boot file rebuild also needs the TPM policy rewritten: the policy hook (above, "Measured boot")
runs after Limine's own.

1. **A Limine post hook, `/etc/boot/hooks/post.d/85-monarchy-encryption-editor`**, linked by `setup` next to the
   fallback hook. Limine's tools run it before their own `90-limine-enroll-config` whenever they rewrite the menu, so
   the editor is locked *before* the checksum is enrolled. There is no moment when an enrolled menu has an editor,
   and nothing has to notice the change afterwards.
2. **A pacman hook, `zz-monarchy-encryption.hook`**, sorted after every Limine and Omarchy hook. It runs `reassert`
   after transactions that touch the kernel, initramfs hooks, firmware, systemd, cryptsetup, Limine, mkinitcpio,
   Omarchy's packages or this one. Upgrading this package therefore also brings laptops set up by an older
   version up to date (new hooks get linked).
3. **`reassert`** runs `setup`'s parts that need no key and no question: the initramfs drop-in and crypttab line,
   the menu settings, the Limine hooks, a rebuild when the menu isn't protected, and the TPM policy rewritten when it
   doesn't cover the files on the ESP. It never touches keyslots. A TPM that no longer opens the disk is reported,
   since re-enrolling needs the recovery key (`setup`). Before `setup` it does nothing.

**No Omarchy post-update hook** (monarchy-identity has one). `omarchy update` installs packages through pacman, so the
pacman hook runs, and its migrations rebuild through Limine's tools, so the editor hook runs. Nothing it does is left
for a post-update hook to catch.

**No watcher on the ESP.** A path unit or timer could catch changes made outside Limine's tools and pacman, but the
project takes no such machinery, and the cases found all go through one of the two.

## Provisioning and factory reset

**Decision:** fleet laptops come from a **full unattended install**, not Omarchy's deferred provisioning, until Omarchy
offers the hooks below. `setup` refuses while provisioning is pending (#30). A factory reset starts with `release`
(#31). Issue #9 (design only), October 2026, Omarchy 4.0.5; evidence in findings.md, "Omarchy's
provisioning and factory reset".

**The flow that works today** (README, "Setting up a laptop"):

1. Unattended install with a disk passphrase the MDM generates for this laptop, separate from the user's password.
2. `setup` with that passphrase on stdin; the MDM stores the recovery key it returns.
3. Restart, with nothing typed: TPM unlock, the passphrase removed (`boot`, above).
4. `monarchy-identity enroll`: directory sign-in.

No lasting secret crosses the MDM channel except the recovery key, which the MDM is meant to hold. No step needs a
person (until #37, the restart asked for the disk passphrase).

**Why not deferred provisioning yet.** Omarchy's deferred install exists for exactly this hand-off, but its pieces
assume it owns the disk's keys:

| Omarchy does | What it does to a set-up laptop |
|---|---|
| Unlocks the provisioning window with `cryptkey=` and a key file in the initramfs | The systemd initramfs ignores `cryptkey=`: after `setup` the disk asks for a throwaway passphrase nobody knows (tested). |
| First-boot re-key: add the owner's password, kill every other slot | Removes the TPM and recovery slots; the owner's password becomes the disk passphrase again (the consumer model this project replaces). |
| Asks the owner on tty1 for a local account | A fleet laptop's people sign in with their directory account (monarchy-identity). |

Ordering our own unit around `omarchy-provision-owner.service` doesn't fix these: before it, the disk can't be
handed a TPM slot that survives the re-key; after it, the throwaway key is gone and the disk passphrase is the
owner's, which the MDM doesn't know. And a run at first boot has nobody to hand the recovery key to: it must reach
the MDM, never the disk. What would make it work is upstream (#32): a systemd-compatible auto-unlock (a key file in
`/etc/crypttab`, or `rd.luks.key=`), a re-key that removes only the slot it staged, and a hook after user creation
where `setup` and `monarchy-identity enroll` run with the staged key file as their secret.

**Factory reset: `release` first.** `omarchy-system-factory-reset` asks for the disk passphrase, which `setup` removed,
and rebuilds the boot files from the install-time `@factory` snapshot, which the TPM policy doesn't cover. Wrapping
Omarchy's reset in a command of ours was rejected by the owner as more machinery than it's worth. Instead, `release` (#31) turns
the laptop back into a plain Omarchy one, and the admin then uses Omarchy's own reset:

1. Ask for a new disk passphrase (twice on a terminal, or one line on stdin) and add it, unlocked by the TPM
   (`cryptsetup luksAddKey --token-only --token-type systemd-tpm2`, the new key through a pipe), or by the recovery
   key when the TPM no longer opens the disk. Skipped when the disk still has a passphrase.
2. Prove it opens the disk, then remove the TPM slot. The recovery key stays (the reset's re-key removes it).
3. Remove the TPM policy (`remove-policy` frees its NV index), our boot file descriptions and the recovery PIN.
4. Unlink the boot service and our Limine hooks; `reassert` finds setup hasn't run and does nothing.

The systemd initramfs, the crypttab line and the menu settings stay: they work with a passphrase, and a reset
replaces them anyway. `setup` sets a released laptop up again. It is also how
a laptop leaves management without a reset. In the lab (`test/vm/e2e-release.sh`): release, restart with the new
passphrase, Omarchy's reset (it takes the new passphrase), first-boot setup, then `setup` back to protected.

**Failure modes, and what each leaves:**

- `setup` run while provisioning is pending: a disk that asks for a passphrase nobody knows; the recovery key opens
  it. Prevented by #30.
- Factory reset without `release`: the reset asks for a disk passphrase there no longer is, and its boot files aren't
  in the TPM policy, so the next start asks too. The recovery key opens the disk at both prompts (not tested).
- Provisioning's re-key after `release` and a reset (as designed): the recovery slot is gone and the owner's password
  opens the disk. Expected; `setup` takes it back.
