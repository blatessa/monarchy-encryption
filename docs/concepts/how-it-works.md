# How it works

## At boot

1. The firmware starts the boot loader (Limine), which starts the laptop's boot image. With Secure Boot on, the firmware
   only starts files signed with **this laptop's own key**, which `setup` created on the laptop.
2. The firmware records in the TPM which Secure Boot keys are in place and whether Secure Boot is on (TPM register
   PCR 7).
3. The boot image asks the TPM for the disk's key. The TPM hands it over only if PCR 7 holds what it held when `setup`
   tied the disk to it. Then the disk opens, and the login screen appears.

If anything about Secure Boot changed (it's turned off, its keys were changed, the firmware was updated), the TPM keeps
the key, and the laptop asks for the **recovery key** at the usual disk prompt.

## What's checked, and what isn't

The TPM vouches for **Secure Boot's state**, not for each file. That's what lets kernel and Omarchy updates go through
without asking anyone: the laptop signs each new boot image with its own key, and nothing the TPM checks changes.

It means:

- **Another operating system, a live USB, or the laptop with Secure Boot off** gets no key, so the disk stays locked.
- **The boot menu can't be used to get a shell.** Its editor is off and Limine refuses a menu file that was changed
  behind its back, so nobody can add `init=/bin/sh` at the menu. `setup` keeps it that way through updates.
- **Someone who is already root on the laptop** could build and sign a different boot image. Root can read the open disk
  anyway, so this protects the disk at rest, not against the laptop's own administrators. Binding the TPM to the boot
  image itself is [planned](https://github.com/blatessa/monarchy-encryption/issues/26).
- **The firmware's settings screen** can turn Secure Boot off unless it has a password. That doesn't open the disk (it
  asks for the recovery key), but a firmware password is still worth setting.

## The keys to the disk

A disk encrypted with LUKS can have several keys. After `setup`:

| Key | Who has it | Used |
|---|---|---|
| The TPM | the laptop itself | every normal start |
| The recovery key | you, or your MDM | when the TPM won't (firmware changes, repairs), and to change keys |
| The install passphrase | removed by `setup` | (Omarchy's installer set it; it's often the first user's password too) |

`setup` never removes a key before checking that another one opens the disk, and it never writes the recovery key to
the laptop or its logs. Replacing it leaves a line in the journal (`journalctl -t monarchy-encryption`).

## Staying correct through updates

Kernel, Limine and Omarchy updates rebuild the boot files. Limine's tools sign them with the laptop's key on the way, and
a hook locks the boot menu before its checksum is sealed into Limine. After every package update, a pacman hook runs
`monarchy-encryption reassert`, which puts back anything an update undid (a Limine upgrade replaces the signed Limine
with an unsigned one, for example). It needs no key and never touches the disk's keys.

## Why two runs of setup

Secure Boot only takes effect at the next start, and the TPM can only be tied to Secure Boot once it's on. So the first
run sets up Secure Boot and the recovery key, and the second, after a restart, ties the disk to the TPM.
