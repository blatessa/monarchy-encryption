# monarchy-encryption

[![CI](https://github.com/blatessa/monarchy-encryption/actions/workflows/ci.yml/badge.svg)](https://github.com/blatessa/monarchy-encryption/actions/workflows/ci.yml)
[![Docs](https://github.com/blatessa/monarchy-encryption/actions/workflows/docs.yml/badge.svg)](https://docs.monarchy.run/monarchy-encryption/)

Disk unlock for [Omarchy](https://omarchy.org) laptops that more than one person signs in to. The laptop's TPM unlocks
its encrypted disk at boot, protected by Secure Boot with the laptop's own keys, and IT holds a recovery key. Nobody
types a disk passphrase, so the login screen becomes the place people prove who they are.

- Secure Boot with each laptop's own keys, and a boot menu that can't be edited.
- TPM unlock tied to Secure Boot; a per-laptop recovery key, shown once for you or your MDM to store.
- Keeps working through kernel, Limine and Omarchy updates.
- Scriptable: secrets on standard input, `--json` output, and `status --json` for MDMs.
- `release` undoes it all, before a factory reset or when a laptop leaves management.

It does disk unlock only: sign-in is [monarchy-identity](https://github.com/blatessa/monarchy-identity)'s job, and
device management belongs to your MDM. Tested in a virtual machine so far, not yet on laptop hardware.

## Quick start

```bash
sudo pacman -U monarchy-encryption-*.pkg.tar.zst   # from the latest release
sudo monarchy-encryption setup                     # disk passphrase; prints the recovery key: store it
# restart, type the passphrase one last time
sudo monarchy-encryption setup                     # recovery key; the TPM takes over, the passphrase goes
monarchy-encryption status
```

The package is on the [releases page](https://github.com/blatessa/monarchy-encryption/releases).

## Documentation

**<https://docs.monarchy.run/monarchy-encryption/>**. Start with
[Getting started](https://docs.monarchy.run/monarchy-encryption/getting-started/).

Contributing: [CONTRIBUTING.md](CONTRIBUTING.md). Security: [SECURITY.md](SECURITY.md). MIT licensed.
