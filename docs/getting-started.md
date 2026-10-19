# Getting started

By the end of this page one Omarchy laptop starts without asking for a disk passphrase, and you hold its recovery key.
Try it on a spare laptop or a virtual machine first.

## 1. Check the laptop

- **Omarchy 4**, installed with disk encryption (the default), on a laptop that starts in UEFI mode.
- **A TPM 2.0**, turned on in the firmware settings (some firmwares call it PTT or fTPM).
- **Secure Boot keys cleared.** In the firmware settings, find Secure Boot and choose "reset to setup mode" or "clear
  keys" (the wording varies). `setup` says so if this is missing, and changes nothing.
- **First-boot setup finished**, if the laptop was installed for a later owner or factory reset.
- **The disk passphrase**: the one chosen at install.

Setting a **firmware password** is worth doing too: without one, anyone at the laptop can turn Secure Boot off in the
firmware settings. That doesn't open the disk (the laptop then asks for the recovery key), but it's the next door to
close.

## 2. Install

Download the `.pkg.tar.zst` file and `SHA256SUMS` from the
[releases page](https://github.com/blatessa/monarchy-encryption/releases), then:

```bash
sha256sum -c --ignore-missing SHA256SUMS
sudo pacman -U monarchy-encryption-*.pkg.tar.zst
```

Installing changes nothing until you run `setup`.

## 3. Set up, first run

```bash
sudo monarchy-encryption setup
```

It asks for the disk passphrase, checks it opens the disk, then switches the laptop to the boot environment TPM unlock
needs, gives it its own Secure Boot keys and signs everything that starts. Last, it prints the laptop's **recovery
key**: eight groups of eight letters.

**Store the recovery key now**, in a password manager or your MDM's record for the laptop. It's shown only once and
never written to the laptop.

## 4. Restart

Restart the laptop and type the disk passphrase one last time. Secure Boot is on from this start.

## 5. Set up, second run

```bash
sudo monarchy-encryption setup
```

This time give it the **recovery key** instead of the passphrase. It ties the disk to the TPM, checks the TPM opens it,
then removes the disk passphrase, which proves both that the recovery key works and that you have it.

```bash
sudo monarchy-encryption status
```

`Protected: yes`. From now on the laptop starts without asking for anything, and the login screen is where people sign
in. When something changes that the TPM can't vouch for (Secure Boot turned off, a firmware update), the disk asks for
the recovery key: type it there, then run `setup` again with it.

## What now

| You want to | Read |
|---|---|
| Set up many laptops from an MDM, with nobody at the keyboard | [Roll out to a fleet](guides/rollout.md) |
| Replace the recovery key, handle firmware updates, factory reset | [Manage laptops](guides/manage.md) |
| Understand what the TPM checks and what it doesn't | [How it works](concepts/how-it-works.md) |
| Know what `setup` or `status` is telling you | [Troubleshooting](guides/troubleshooting.md), [CLI](reference/cli.md) |
