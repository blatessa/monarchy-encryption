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
monarchy-encryption status [--json]                # protected or not, and what's missing: docs/reference/status-output.md
monarchy-encryption recovery-key [--json]   # create or replace; printed once for the caller to store
monarchy-encryption reassert                # put back boot settings and signatures an update undid (run by pacman)
monarchy-encryption release                 # undo setup: a passphrase again, Secure Boot handed back
```

It's called by a person or by an MDM, the same way `monarchy-identity enroll` is.

## Setting up a laptop

`setup` runs twice, with a restart in between: Secure Boot only takes effect at the next start, and the TPM can only
be tied to it after that. Each run needs a key the disk already opens with. The firmware's Secure Boot keys have to be
cleared first (in its settings, "reset to setup mode" or "clear keys"); `setup` says so if they aren't. A laptop
installed for a later owner, or factory reset, must finish Omarchy's first-boot setup before `setup` will run.

### A laptop that's already in use

You know its disk passphrase, so type it when asked:

```bash
sudo monarchy-encryption setup     # asks for the disk passphrase; prints the recovery key: store it now
# restart the laptop (you type the passphrase one last time)
sudo monarchy-encryption setup     # give the recovery key this time, and the passphrase is removed
```

If you give the passphrase instead of the recovery key in the second run, the TPM still unlocks the disk, and the
passphrase keeps working until you run `setup` once more with the recovery key.

### New laptops, from an MDM

Install Omarchy unattended (omarchy-iso's README, "Unattended installs") with a **disk passphrase your MDM generates
for each laptop**, separate from the user's password: `encryption_password` in `user_credentials.json` and in
`disk_encryption` in `user_configuration.json`. Your MDM then knows it, nobody has to type it, and `setup` removes it
at the end. The MDM gives each run its secret on stdin and reads `--json` (`"done": false` means restart, then run
again):

```bash
printf '%s\n' "$DISK_PASSPHRASE" | monarchy-encryption setup --json   # {"done":false,"recovery_key":"…",…}: store the key
# restart
printf '%s\n' "$RECOVERY_KEY"    | monarchy-encryption setup --json   # {"done":true,"passphrase":"removed",…}
```

### Afterwards

The laptop starts without asking for anything, and the login screen is where people sign in. The disk asks for the
recovery key only when the laptop's boot software or firmware settings changed: Secure Boot turned off, its keys
changed, or a firmware update. Type the recovery key there, then run `setup` again with it to let the TPM unlock the
disk again. `status` tells you whether a laptop is set up this way and, if not, what's missing.

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

## Giving a laptop back, or factory resetting it

```bash
sudo monarchy-encryption release   # asks for a new disk passphrase
```

`release` undoes `setup`: the disk unlocks with the new passphrase again, and the firmware's Secure Boot keys are
handed back (Secure Boot is off from the next start). The disk stays encrypted. An MDM gives the new passphrase on
stdin; if the laptop can't unlock itself any more (after a firmware update, say), give the recovery key as a second
line.

To factory reset the laptop, run `release` first, then Omarchy's reset (`omarchy-system-factory-reset`), which asks
for the passphrase you just set. Without `release`, the reset leaves boot files the firmware refuses to start. Once
first-boot setup has run, `setup` sets the laptop up again.

## What it won't do

- Sign-in, directory accounts, autologin: that's monarchy-identity.
- Store recovery keys: it hands them to the caller (MDM, script) to store.
- General device management (firewall, updates, inventory): that's the MDM.

It doesn't depend on monarchy-identity, and identity doesn't depend on it.

## Documents

- [AGENTS.md](AGENTS.md): rules, scope and how to pick work.
- [docs/reference/status-output.md](docs/reference/status-output.md): what `status` reports, for people and MDMs.
- [docs/research.md](docs/research.md): what Omarchy already provides and the known traps.

MIT, see [LICENSE](LICENSE).
