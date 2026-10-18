# monarchy-encryption

Disk unlock for [Omarchy](https://omarchy.org) laptops that more than one person signs in to. A small utility that lets
the TPM unlock the encrypted disk at boot, protected by Secure Boot, with a recovery key IT can hold, so the login
screen becomes the place people prove who they are.

> **Status: in progress, not ready for use.** `setup` switches the laptop to a systemd initramfs and turns on Secure
> Boot with the laptop's own keys; TPM unlock and the recovery key are not built yet. Work is tracked in
> [issues](https://github.com/blatessa/monarchy-encryption/issues); start with [AGENTS.md](AGENTS.md).

## Why

Omarchy encrypts the disk with one password that is also the user's login and root password, and signs the user in
automatically after the disk is unlocked: the disk prompt is the sign-in. That is right for a personal laptop. On a
company laptop where people sign in with their own directory account
([monarchy-identity](https://github.com/blatessa/monarchy-identity)), it means every person must know a shared disk
passphrase and type two secrets at boot.

The standard answer (BitLocker does this on Windows) is:

- the **TPM** releases the disk key at boot, but only if the machine booted the expected, signed software;
- **Secure Boot** with the organisation's own keys makes "expected software" mean something;
- a per-laptop **recovery key**, held by IT, covers firmware changes and repairs;
- the **login screen** is where people authenticate.

## What it will do

```text
monarchy-encryption setup          # Secure Boot keys + signing, systemd initramfs, TPM enrollment, recovery key
monarchy-encryption status [--json]
monarchy-encryption recovery-key   # create or rotate; printed once for the caller to store
monarchy-encryption reassert       # keep signing and boot config right after updates
```

It's called by a person or by an MDM, the same way `monarchy-identity enroll` is.

## What it won't do

- Sign-in, directory accounts, autologin: that's monarchy-identity.
- Store recovery keys: it hands them to the caller (MDM, script) to store.
- General device management (firewall, updates, inventory): that's the MDM.

It doesn't depend on monarchy-identity, and identity doesn't depend on it.

## Documents

- [AGENTS.md](AGENTS.md): rules, scope and how to pick work.
- [docs/research.md](docs/research.md): what Omarchy already provides and the known traps.

MIT, see [LICENSE](LICENSE).
