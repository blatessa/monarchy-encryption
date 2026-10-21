# Findings

Non-obvious lessons, each with where it was seen. Newest last.

## Omarchy's unattended install needs the disk passphrase in `user_credentials.json`

Seen: Omarchy 4.0.5 release ISO (iso commit 3872d5a), October 2026, building the lab (`test/vm/install.sh`).

The omarchy-iso README says encryption is configured by the `disk_encryption` block in `user_configuration.json`.
With the passphrase only there, archinstall installs the disk **unencrypted** without a word. The install then halts
at its last phase ("Encrypted install but /mnt/boot/limine.conf has no cryptdevice="), because
`user_encrypt_installation.txt` said `true`. The configurator also writes the passphrase as `encryption_password` in
`user_credentials.json`, and that is the copy archinstall reads. Put it in both places.

## A serial port turns Plymouth's disk prompt into plain text

Seen: the lab, Omarchy 4.0.5, October 2026.

With a serial port on the VM, the firmware lists it as a console, systemd's UKI stub appends
`console=uart,io,0x3f8 console=tty0` to the kernel command line (it isn't in the UKI or in `limine.conf`), and Plymouth
then shows a plain-text passphrase prompt instead of Omarchy's themed screen. The busybox and systemd initramfs both
do it. The lab boots with no serial port unless `LAB_SERIAL=1` (only `install.sh` sets it), so its screen matches a
laptop's.

## Omarchy's busybox hooks all have systemd equivalents

Seen: Omarchy 4.0.5 (mkinitcpio 42.2, limine-mkinitcpio-hook 1.40.0, systemd 262), October 2026; spike #3.

| Omarchy (busybox) | systemd initramfs | Note |
|---|---|---|
| `udev` | `systemd` | |
| `keymap`, `consolefont` | `sd-vconsole` | Only when Omarchy bundles `/etc/vconsole.conf` (Latin layouts): sd-vconsole always puts the layout in, and a non-Latin one makes the passphrase untypeable (Omarchy #6229). |
| `encrypt` | `sd-encrypt` | The disk comes from crypttab, not `cryptdevice=`. |
| `btrfs-overlayfs` | `sd-btrfs-overlayfs` | Same package (limine-mkinitcpio-hook). The busybox one is a runscript, which a systemd initramfs never runs: snapshot entries would boot read-only. |
| `resume` | (none) | systemd resumes from `resume=`/`resume_offset=` itself. |
| `plymouth` | `plymouth` | The same hook installs the systemd units (themed prompt confirmed). |

`/etc/crypttab.initramfs` still works but mkinitcpio 42 calls it deprecated: use a line in `/etc/crypttab` with
`x-initrd.attach`. Naming the mapping `root` keeps `/dev/mapper/root`, so `root=` and `resume=` don't change, and
`cryptdevice=` can stay on the command line (ignored by systemd). Omarchy's first-boot setup, factory reset and Quattro
upgrade read `cryptdevice=` to find the LUKS partition (they also fall back to walking the device tree).

## systemd 262's NvPCR setup fails in the lab

Seen: lab VM (swtpm), Omarchy 4.0.5, systemd 262, on every boot including stock. `systemd-tpm2-setup-early`,
`systemd-pcrproduct` and `systemd-pcrlogin@` fail with "Failed to initialize NvPCR index: No such file or directory".
The SRK itself is set up (`SRK already stored in the TPM`), so `systemd-cryptenroll --tpm2-device` is not affected.
The host laptop (systemd 261.2, a hardware TPM) initializes its NvPCRs. Revisit in #5: swtpm or 262?

## Running `omarchy update` in the lab

Seen: Omarchy 4.0.5. A direct `pacman -Syu` is refused by Omarchy's `00-omarchy-update-guard` hook. `omarchy update -y`
over ssh needs `OMARCHY_PATH=/usr/share/omarchy` (the desktop session sets it), passwordless sudo that sorts after
Omarchy's sudoers files, and `Defaults verifypw=any` (its stay-awake step runs `sudo -v`). Even with `-y`, it then
waits at the orphan-packages step; packages, migrations and post-update hooks have run by then.

## Limine and the boot menu

Seen: Omarchy 4.0.5, limine 12.9.3, limine-mkinitcpio-hook 1.40.0, in the lab; issue #4.

- `ENABLE_ENROLL_LIMINE_CONFIG` is read only from `/etc/default/limine`. `limine-common-functions` clears it after
  loading the drop-ins. The enrolled checksum is the BLAKE2B of `limine.conf`, stored in the binary as hex text, so
  `grep -aF "$(b2sum limine.conf | cut -d' ' -f1)" limine_x64.efi` tells whether the current menu is the enrolled one.
- A menu that doesn't match: `PANIC: !!! CHECKSUM MISMATCH FOR CONFIG FILE !!!`, System halted. No fallback helps,
  since it carries the same checksum.
- `limine-install` copies `/usr/share/limine/BOOTX64.EFI` (plain, unsigned, nothing enrolled) to `EFI/BOOT/BOOTX64.EFI`
  on every run whenever it differs, and runs the post hooks last (on exit). Omarchy sets `ENABLE_LIMINE_FALLBACK=yes`
  and `FIND_BOOTLOADERS=yes`, so the menu also gets an "EFI fallback" entry chainloading it.
- `editor_enabled: no` removes both "E Edit" and "B Blank Entry" from the menu. "S Firmware Setup" stays.
- Omarchy's `limine.conf` has `hash_mismatch_panic: no`, but once the config is enrolled Limine enforces the hashes
  anyway: a boot image whose BLAKE2B doesn't match its `path: …#hash` gives `PANIC: Blake2b hash for URI … does not
  match!`, System halted.
- Snapshot boot entries start the boot image as it was when the snapshot was taken, pinned by hash both in
  `limine.conf` and in limine-snapper-sync's `snapshots.json`. While it's the current one, the entry uses the same file
  (`EFI/Linux/…`) with the snapshot's command line from the menu; once a new boot image is built, the old one is kept
  as a copy (`<esp>/<machine-id>/limine_history/…efi_sha256_…`).
- The ESP (FAT, `umask=0077`) is root-only.

## Hibernation and reboots are unreliable in the lab

Seen: lab VM, Omarchy 4.0.5, October 2026, while testing #18.

- **Resume:** hibernation always writes its image (2 GB in about 1.5 s, then the VM powers off), but the next start
  often doesn't find it: `Unable to resume from device '/dev/mapper/root' (253:0) offset 1535226, continuing boot
  process`. Counts with `test/vm/hibernate-loop.sh`: a stock install (busybox initramfs) resumed 1 of 5 times; after
  `setup` (systemd initramfs, Secure Boot) 2 of 2, plus single successes on both earlier. So the systemd initramfs
  isn't what makes it unreliable. Uptime at hibernation made no difference (failures at 43 s, successes at 14 s).
- **Hang:** some reboots end on a black screen with ssh refused and nothing in the journal, on stock as well as after
  `setup`. Three of the four seen came at the first reboot after a successful resume, including the one in spike #3,
  but one reboot after a resume went through cleanly.
- Not explained yet: #21. Until it is, lab suites that hibernate retry, and a hang means a lab problem before it means
  a product one.

## Recovery keys

Seen: lab VM, Omarchy 4.0.5, systemd 262, cryptsetup 2.8, October 2026; issue #6.

- `systemd-cryptenroll --recovery-key` prints the key on **stdout** (8 groups of 8 modhex letters joined by `-`).
  The explanation and `New recovery key enrolled as key slot N.` go to stderr, without the key, but the key is
  written in the middle of a stderr line (`    🔐 ` before it, the newline after), so with both captured together it
  is not a line of its own: find it by its pattern. A first version expected a whole line, found none, and left an
  enrolled slot whose key nobody had; the CLI now removes such a slot again. It
  adds a `systemd-recovery` token naming the slot, which is how `luksDump --dump-json-metadata` tells recovery slots
  from passphrase ones. There is no `--json` for enrolling (`unrecognized option '--json'`).
- **Piping the passphrase in doesn't work**: with no `--unlock-*` option, it asks through the password agent
  (`systemd-tty-ask-password-agent --wall`) and waits forever, whatever is on stdin. `PASSWORD=` in the environment
  is read. `--unlock-key-file=/dev/stdin` with the passphrase piped in works, but only **without a trailing newline**
  (with one: `Unlocking via keyfile failed: Operation not permitted`). The CLI uses the pipe, which keeps the
  passphrase out of `/proc/*/environ`.
- A recovery key unlocks the volume for enrolling like any passphrase.
- `--unlock-tpm2-device=auto` with no TPM slot fails at once (rc 1, `No TPM2 metadata enrolled in LUKS2 header.`).
- `--wipe-slot=N` asks for no key at all: root can remove any slot. It refuses only to remove every slot.
- **Lab: never put a secret in a command line run with sudo.** sudo logs every command line to the journal, so
  `lab_ssh_root bash -c "printf KEY | …"` writes the key to the laptop, and a leak check that greps for it fails
  because of the test itself. `e2e-recoverykey.sh` sends secrets on stdin after sudo's password (`root_with`):
  `sudo -S` reads only its own line and the command gets the rest.

## TPM unlock

Seen: lab VM (swtpm), Omarchy 4.0.5, systemd 262, October 2026; issue #5 (then bound to PCR 7; see "Measured boot").

- `systemd-cryptenroll --unlock-key-file=/dev/stdin --tpm2-device=auto --tpm2-pcrs=7` enrolls in a few seconds and
  prints `New TPM2 token enrolled as key slot N.` The token (`systemd-tpm2`) records `tpm2-pcrs: [7]` and the bank.
- `cryptsetup open --test-passphrase --token-only --token-type systemd-tpm2 DEV` proves the TPM opens the disk now,
  through `/usr/lib/cryptsetup/libcryptsetup-token-systemd-tpm2.so`, the same token systemd-cryptsetup uses at boot.
- **No `tpm2-device=auto` is needed in `/etc/crypttab`**: with the token in the header, the initramfs unlocked with
  nothing typed (about 15 s to ssh).
- **Once a TPM token exists, `cryptsetup open --test-passphrase --key-file=- DEV` succeeds with any key**: it tries
  the token first (`Key slot 0 unlocked.`, the TPM's slot) and never looks at the key. A first version of the CLI
  checked the caller's key this way, so a wrong one got past setup's check, and the lab test "the passphrase no
  longer opens the disk" failed although it was gone. Test a key with `--disable-external-tokens` (or `--key-slot=N`
  of a slot with no token); the cryptsetup stub now behaves the same way.
- When PCR 7 doesn't match, `systemd-cryptsetup@root` logs `TPM policy does not match current system state. Either
  system has been tampered with or policy out-of-date: Operation not permitted` and shows the normal themed prompt; the
  recovery key or passphrase opens the disk there.
- **The one-time unlock** (#37, same lab): `--tpm2-pcrs=` (empty) binds to no PCRs; the token records `tpm2-pcrs:
  []`, which is how setup tells it from the PCR 7 one. It opens the disk with Secure Boot off and at the restart with
  it on, with nothing typed. With two TPM tokens, `cryptsetup open --test-passphrase --token-only --token-id=N DEV`
  tests one of them (by token id, from `luksDump --dump-json-metadata`).
  `systemd-cryptenroll --unlock-tpm2-device=auto` enrolls the PCR 7 slot unlocked by the one-time one.

## Measured boot

Seen: lab VM (OVMF, swtpm), Omarchy 4.0.5, systemd 262, October 2026, and a read-only check on an MSI laptop (AMI
firmware); issue #26.

- **Laptops ship with the manufacturer's platform key enrolled**, even with Secure Boot off and `SetupMode` reading 1
  on the MSI: its PK ("MSI SHIP PK") was immutable from the OS, and writing db gave "permission denied". Enrolling
  our own keys needs a visit to the firmware settings; the lab, which starts with no keys, never showed it.
- **systemd-pcrlock** is `/usr/lib/systemd/systemd-pcrlock`, not on `PATH`. `make-policy` keeps the policy in a TPM
  NV index and writes `/var/lib/systemd/pcrlock.json` and `/boot/loader/credentials/pcrlock.<machine-id>.cred`, which
  systemd-stub hands to the initramfs (with Limine too). `systemd-cryptenroll --tpm2-pcrlock=FILE` records
  `tpm2_pcrlock: true` and `tpm2-pcrs: []`; without `--tpm2-pcrlock=`, cryptenroll picks up `pcrlock.json` by
  itself, even for `--tpm2-pcrs=`.
- **PCR 4** holds the firmware's "Calling EFI Application" action, the separator, then each EFI program it started:
  Limine and the boot image Limine chainloaded. A snapshot or a new boot image changes `limine.conf`, so the enrolled
  checksum, so Limine's hash. **PCR 12 and 9** get pcrlock's own credential ("Global credentials initrd"), measured
  after the policy is made: unusable. **PCR 5** had an Exit Boot Services retry in OVMF.
- **A stock Omarchy start measures nothing in the initrd**: the busybox initramfs doesn't run systemd's
  measurements, so `predict --strict` with `/usr/lib/pcrlock.d` reports "Couldn't find component '750-enter-initrd'"
  (PCR 11) and '750-os-separator' (PCRs 0-14) and drops PCR 4 and 11. Without those two components it matches.
- **pcrlock's default recovery PIN is sealed behind the policy itself**: after one start that missed the policy, it
  can never be rewritten (`Esys_PolicyOR` TPM error 0x1c4). With our own PIN (`$PIN` and `--recovery-pin=query`; with
  no `$PIN` it waits for an agent forever) it can.
- **limine-snapper-sync runs Limine's hooks with `ProtectHome=yes`**: a PIN under `/root` read as empty, and the
  write failed with "Failed to write to NV index: State not recoverable" (0x99d). It also runs them twice within a
  second.
- **A cleared TPM gets no NV index from `make-policy`** when the prediction hasn't changed ("Prediction is identical
  to current policy, skipping update"), so a new enrollment fails to open the disk. `remove-policy` then
  `make-policy` writes it afresh.

## The disk passphrase can differ from the user's password

Seen: Omarchy 4.0.5 release ISO, unattended install, October 2026 (a one-off copy of `test/vm/install.sh`).

`user_credentials.json` takes the disk passphrase (`encryption_password`, plain text, also needed in
`disk_encryption` in `user_configuration.json`: see above) separately from the user's password (`users[].enc_password`,
a crypt hash). Installed with different values, the disk opens only with `encryption_password`, and the user's
password works for sudo but not for the disk. So a fleet install can give each laptop a disk passphrase that only the
MDM knows, and `setup`'s second run removes it.

## Updates after setup

Seen: lab VM, Omarchy 4.0.5, limine 12.9.3, limine-mkinitcpio-hook 1.40.0, October 2026; issue #7.

- **A limine upgrade (or reinstall) leaves a plain Limine.** pacman runs hooks in name order across
  `/usr/share/libalpm/hooks` and `/etc/pacman.d/hooks`. Limine's `80-limine-efi-deploy` runs `limine-install`, which
  enrolls the menu. Then Omarchy's `/etc/pacman.d/hooks/99-omarchy-limine.hook` copies the plain
  `/usr/share/limine/BOOTX64.EFI` over `EFI/limine/limine_x64.efi`: nothing enrolled, so it boots any menu.
  `zz-monarchy-encryption.hook` sorts after it and rebuilds.
- **`omarchy-refresh-limine` re-opens the boot menu editor**, correctly enrolled: it copies Omarchy's default
  `limine.conf` (no `editor_enabled: no`) over ours and runs `limine-update`, which enrolls the new menu's checksum.
  Everything is signed and the laptop starts with the TPM, but the menu can be edited again. Limine runs its post
  hooks (`/etc/boot/hooks/post.d`) in name order, its own `90-limine-enroll-config` among them, so a hook named `85-`
  can lock the menu before its checksum is enrolled.
- **Kernel updates and Omarchy migrations stay correct** on their own. Every migration that rebuilds the boot image
  goes through `limine-mkinitcpio` or `limine-update`, which run Limine's post hooks. The ones in 4.0.5 edit only
  `BOOT_ORDER` in `/etc/default/limine` and their own drop-ins, never our `ENABLE_ENROLL_LIMINE_CONFIG` line or
  `zz-monarchy-encryption.conf`. No migration runs `omarchy-refresh-limine`.

## Omarchy's provisioning and factory reset

Seen: Omarchy 4.0.5 in the lab (reading `omarchy-provision-owner` and `omarchy-system-factory-reset`, and trying the
auto-unlock), October 2026; issue #9.

- **Deferred provisioning auto-unlocks with a busybox-only mechanism.** A deferred install, or a factory reset, stages
  a throwaway passphrase as `/var/lib/omarchy/provisioning/luks-key` and `/etc/omarchy/provisioning.key`, bundles the
  latter into the initramfs (`99-omarchy-provisioning-key.conf`, `FILES+=`), and adds
  `cryptkey=rootfs:/etc/omarchy/provisioning.key` to the command line. The busybox `encrypt` hook reads `cryptkey=`.
  **The systemd initramfs ignores it**: in the lab, with the key file in the boot image and on the command line, the
  busybox initramfs unlocked with nothing typed, and after `setup`'s first run the disk asked for a passphrase. A
  laptop set up while provisioning is pending asks for a passphrase nobody knows; only the recovery key opens it.
- **First-boot provisioning removes every other keyslot.** `rekey_luks` adds the new owner's password with the staged
  key, rebuilds the boot files without the auto-unlock, then `luksKillSlot`s every slot but the owner's: on a laptop
  that's set up, the TPM and the recovery key. It also copies Omarchy's template `limine.conf` over ours (the editor
  hook from #7 locks it again).
- **A factory reset asks for the "current disk encryption passphrase"**, which a set-up laptop no longer has; the
  recovery key works there. It adds the throwaway slot and leaves the others to provisioning (above).
- **A factory reset rebuilds the boot files inside the `@factory` snapshot** (`chroot "$next" limine-update`), taken
  right after the install: no `ENABLE_ENROLL_LIMINE_CONFIG=yes`, no monarchy-encryption, so none of our hooks run.
- The lab install (Omarchy 4.0.5 ISO, `defer_provisioning: false`) has an `@factory` subvolume, so a factory reset can
  be tried there.

## Driving Omarchy's factory reset and first-boot setup in the lab

Seen: lab VM, Omarchy 4.0.5, gum 0.17 (bubbletea v2), October 2026; issue #31 (`test/vm/e2e-release.sh`).

- **gum panics on a terminal with no size** (`runtime error: makeslice: len out of range` in
  `textinput.placeholderView`). `script -qec CMD /dev/null` over a non-interactive ssh gives a 0-column pty: run
  `stty cols 120 rows 40` first. The reset's prompts (type `reset`, the disk passphrase, "Reboot now?") then take
  keystrokes piped through `script`.
- **OCR splits monospaced words**: tesseract reads first-boot setup's `Confirm>` as `Conf irm>`. Compare with spaces
  removed.
- **sshd answers before first-boot setup has finished**: provisioning re-keys the disk in the background on tty1 after
  the form, so wait for `/var/lib/omarchy/provisioning/pending` to go before looking at keyslots. Mid-way the disk had
  the throwaway, recovery and owner slots; afterwards only the owner's.
- **The reset removes every account**, so ssh after it needs a key where provisioning installs one from:
  `/var/lib/omarchy/provisioning/authorized_keys` inside `@factory` (a read-only snapshot: `btrfs property set -ts
  … ro false`, then back). Harness only.
- `@factory` predates our package, so after a reset `monarchy-encryption` has to be installed again.

## An Omarchy factory reset leaves hibernation with no device, which hangs the systemd initramfs

Seen: lab VM, Omarchy 4.0.5, systemd 262, October 2026; issue #31 (`e2e-release.sh`: setup after a factory reset).

- The reset rebuilds hibernation inside a chroot of `@factory` (`omarchy-hibernation-setup --force --no-rebuild`) and
  writes `/etc/limine-entry-tool.d/resume.conf` as `resume= resume_offset=N`: **no device**. Omarchy's busybox
  initramfs ignores an empty `resume=`. The systemd initramfs unlocked the disk and then sat at `A start job is
  running for / (… / no limit)` forever, on every boot. With `resume=/dev/mapper/root` it boots.
- **limine-entry-tool appends `/etc/limine-entry-tool.d/*.conf` to the command line in reverse name order**: a `zz-`
  drop-in landed before Omarchy's `resume.conf`, a `00-` one after it. systemd uses the last `resume=`. So `setup`
  writes `00-monarchy-encryption.conf` with the device when the configuration has a `resume_offset=` and an empty
  `resume=`, and leaves Omarchy's file alone. Reported upstream through #32.
- Found in minutes rather than hours thanks to lab checkpoints: `after-first-boot` saved once, then each attempt
  restored it (about 20 s) instead of replaying release, reset and first-boot setup (about 15 min).

## A fresh Omarchy install can't resolve the package's dependencies

Seen: installing the v0.1.0 release file in the lab (a fresh install from the Omarchy 4.0.5 ISO), October 2026.

The ISO installs from an offline repository and leaves no sync databases (`/var/lib/pacman/sync/` has only
`offline.db`), so `pacman -U monarchy-encryption-*.pkg.tar.zst` fails with `unable to satisfy dependency 'sbctl'`.
After `omarchy update` (or `pacman -Sy`, which Omarchy's guard allows with `OMARCHY_ALLOW_DIRECT_PACMAN=1`) it
installs. The docs say to update first; `test/vm/install-package.sh` syncs before installing.
