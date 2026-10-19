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

## Limine, Secure Boot and the boot menu

Seen: Omarchy 4.0.5, limine 12.9.3, limine-mkinitcpio-hook 1.40.0, sbctl 0.18, in the lab; issue #4.

- Limine's tools sign with sbctl once `sbctl setup --print-state --json` says `"installed": true`, which is true once
  `sbctl create-keys` has run. Before that the output is empty and nothing is signed.
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
- Snapshot boot entries start a copy of the boot image from when the snapshot was taken
  (`<esp>/<machine-id>/limine_history/…efi_sha256_…`), pinned by hash both in `limine.conf` and in
  limine-snapper-sync's `snapshots.json`, which it regenerates the entries from. A copy from before Secure Boot is
  unsigned: the firmware refuses it (`PANIC: efi: LoadImage failure (0x800000000000000F)`). Signing it changes its
  hash, and Limine refuses that instead. `sbctl verify` lists these files although their names don't end in `.efi`.
  Snapshots taken after the keys exist copy the signed image and start fine.
- The firmware variables (SecureBoot, SetupMode, PK, KEK) are world-readable. sbctl's keys
  (`/var/lib/sbctl/keys/*/*.pem`) and the ESP (FAT, `umask=0077`) are root-only. `sbctl list-enrolled-keys` names keys
  only by subject, and sbctl's platform key is always "Platform Key", so whether the firmware's PK is this laptop's is
  answered by finding the DER of `PK.pem` in the PK variable.
- An unsigned EFI program set as `BootNext`: OVMF logs `Access Denied -- rejected probably by Secure Boot`, clears
  BootNext and starts the next entry (Limine).

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
