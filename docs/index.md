# monarchy-encryption

Disk unlock for [Omarchy](https://omarchy.org) laptops that more than one person signs in to. The laptop's TPM unlocks
its encrypted disk at boot, protected by Secure Boot with the laptop's own keys, and IT holds a recovery key. Nobody
types a disk passphrase, so the login screen becomes the place people prove who they are.

## Why

Omarchy encrypts the disk with one password that is also the first user's login and root password, and signs that user
in automatically once the disk is unlocked: the disk prompt is the sign-in. That's right for a personal laptop. On a
company laptop where people sign in with their own directory account
([monarchy-identity](https://docs.monarchy.run/monarchy-identity/)), it means everyone needs a shared disk passphrase
and types two secrets at boot.

The standard answer, the one BitLocker gives Windows, is:

- the **TPM** releases the disk key at boot, but only if the laptop started the expected, signed software;
- **Secure Boot** with the laptop's own keys makes "expected software" mean something;
- a per-laptop **recovery key**, held by IT, covers firmware changes and repairs;
- the **login screen** is where people authenticate.

## What it does

- `setup` takes an Omarchy laptop to TPM unlock in two runs with a restart between, and removes the shared disk
  passphrase at the end.
- `recovery-key` creates or replaces the recovery key, shown once for you or your MDM to store.
- `status` says whether the laptop is protected and, if not, what's missing, in a form an MDM can read.
- Kernel, Limine and Omarchy updates keep the laptop protected; a pacman hook puts back anything an update undid.
- `release` undoes it all before a factory reset, or when a laptop leaves management.

It does disk unlock only: sign-in is [monarchy-identity](https://docs.monarchy.run/monarchy-identity/)'s job, storing
recovery keys is your MDM's, and device management belongs to the MDM.

**Start with [Getting started](getting-started.md)**, on a spare laptop or a virtual machine.
