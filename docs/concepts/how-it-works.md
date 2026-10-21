# How it works

## At boot

1. The firmware starts the boot loader (Limine), and records exactly what it started in the TPM. Limine carries the
   checksum of its boot menu, so the record covers the menu and the kernel command line in it too.
2. Limine starts the laptop's boot image; the firmware records that too, and the boot image records its own parts
   (kernel, startup environment, command line).
3. The boot image asks the TPM for the disk's key. The TPM hands it over only if those records match the boot files
   this laptop approved. Then the disk opens, and the login screen appears.

If the laptop started anything else, the TPM keeps the key, and the laptop asks for the **recovery key** at the usual
disk prompt.

## What's checked, and what isn't

The TPM vouches for **the exact boot files**: Limine, its menu and the boot image. Updates approve the new ones as
they're built (below), so they go through without asking anyone.

It means:

- **Another operating system, a live USB, or a changed boot loader or boot image** gets no key, so the disk stays
  locked.
- **The boot menu can't be used to get a shell.** Its editor is off and Limine refuses a menu file that was changed
  behind its back, so nobody can add `init=/bin/sh` at the menu. `setup` keeps it that way through updates.
- **Snapshots** taken after `setup` start from the boot menu with nothing typed, while their boot image is the
  current one. One from before a kernel update (or before `setup`) has an older boot image the TPM doesn't vouch for:
  it asks for the recovery key.
- **Someone who is already root on the laptop** can approve different boot files: that's how updates work. Root can
  read the open disk anyway, so this protects the disk at rest, not against the laptop's own administrators.
- **The firmware's Secure Boot keys are left as they are.** Nothing in the firmware settings has to change, and a
  firmware update usually doesn't change what the TPM checks.

## The keys to the disk

A disk encrypted with LUKS can have several keys. After `setup`:

| Key | Who has it | Used |
|---|---|---|
| The TPM | the laptop itself | every normal start |
| The recovery key | you, or your MDM | when the TPM won't (changed boot files, a cleared TPM, repairs), and to change keys |
| The install passphrase | removed by `setup` | (Omarchy's installer set it; it's often the first user's password too) |

`setup` never removes a key before checking that another one opens the disk, and it never writes the recovery key to
the laptop or its logs. Replacing it leaves a line in the journal (`journalctl -t monarchy-encryption`).

## Staying correct through updates

Kernel, Limine and Omarchy updates rebuild the boot files, and so do snapshots (the boot menu lists them). Limine's
tools run this tool's hooks on every rebuild: one locks the boot menu before its checksum is sealed into Limine, and
the last tells the TPM about the new boot files, keeping the ones that are running allowed until the next start.
After every package update, a pacman hook runs `monarchy-encryption reassert`, which puts back anything an update
undid (a Limine upgrade replaces Limine with a plain copy, for example). It needs no key and never touches the disk's
keys.

## Why a restart

The TPM can only learn what this laptop's start looks like by watching one, with the boot environment `setup` puts
in. So `setup` sets up that boot environment, the boot menu and the recovery key, and lets the TPM open the disk once,
for the restart, with nothing checked. As the laptop starts, it tells the TPM which boot files started, ties the disk
to them, removes the disk passphrase, and removes that one-time unlock, whatever happens. Between `setup` and that
start, anyone with the laptop could start it and get in, as on an unencrypted disk: restart straight away. The key for
that start never leaves the TPM, so the disk alone, taken out of the laptop, stays locked.
