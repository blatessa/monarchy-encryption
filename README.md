# monarchy-encryption

Disk unlock for [Omarchy](https://omarchy.org) laptops that more than one person signs in to. A small utility that lets
the TPM unlock the encrypted disk at boot, protected by Secure Boot, with a recovery key IT can hold, so the login
screen becomes the place people prove who they are.

> **Status: in progress, not ready for use.** `setup` takes a laptop to TPM unlock with Secure Boot and a recovery
> key, and it stays that way through kernel, Limine and Omarchy updates. Tested in a virtual machine only. Work is
> tracked in [issues](https://github.com/blatessa/monarchy-encryption/issues); start with [AGENTS.md](AGENTS.md).

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

## What it does

```text
monarchy-encryption setup [--json]          # Secure Boot, TPM unlock and a recovery key; runs twice (below)
monarchy-encryption status [--json]
monarchy-encryption recovery-key [--json]   # create or replace; printed once for the caller to store
monarchy-encryption reassert                # put back boot settings and signatures an update undid (run by pacman)
```

It's called by a person or by an MDM, the same way `monarchy-identity enroll` is.

## Setting up a laptop

The firmware's Secure Boot keys have to be cleared first (in its settings, "reset to setup mode" or "clear keys"):
`setup` says so if they aren't. Then:

```bash
sudo monarchy-encryption setup     # asks for the disk passphrase; prints the recovery key: store it now
# restart the laptop (you type the passphrase one last time)
sudo monarchy-encryption setup     # asks again: give the recovery key, and the passphrase is removed
```

After the second run the laptop starts without asking for anything, and the login screen is where people sign in. The
disk asks for the recovery key only when the laptop's boot software or firmware settings changed: Secure Boot turned
off, its keys changed, or a firmware update. Type the recovery key there, then run `setup` again with it to let the
TPM unlock the disk again.

If you give the passphrase instead of the recovery key in the second run, the TPM still unlocks the disk, and the
passphrase keeps working until you run `setup` once more with the recovery key.

An MDM runs the same two steps with the secret on stdin and `--json` (`"done": false` means restart, then run again):

```bash
printf '%s\n' "$PASSPHRASE"   | monarchy-encryption setup --json   # {"done":false,"recovery_key":"…",…}
printf '%s\n' "$RECOVERY_KEY" | monarchy-encryption setup --json   # after the restart: {"done":true,"passphrase":"removed",…}
```

## The recovery key

```bash
sudo monarchy-encryption recovery-key            # prints the new key (asks for a key only before setup is done)
printf '%s\n' "$PASSPHRASE" | sudo monarchy-encryption recovery-key --json   # for an MDM or a script
```

Each laptop has its own recovery key, created by `setup`. It's shown once, when it's created, and never written to
the laptop: store it right away (a password manager, or your MDM's record for the laptop). `recovery-key` replaces it,
and the old one stops working. Once the TPM unlocks the disk, no passphrase is needed to replace it.

When the laptop can't unlock its disk by itself (after a firmware update or a repair, say), type the recovery key at
the disk prompt in place of the passphrase, dashes included.

## What it won't do

- Sign-in, directory accounts, autologin: that's monarchy-identity.
- Store recovery keys: it hands them to the caller (MDM, script) to store.
- General device management (firewall, updates, inventory): that's the MDM.

It doesn't depend on monarchy-identity, and identity doesn't depend on it.

## Documents

- [AGENTS.md](AGENTS.md): rules, scope and how to pick work.
- [docs/research.md](docs/research.md): what Omarchy already provides and the known traps.

MIT, see [LICENSE](LICENSE).
