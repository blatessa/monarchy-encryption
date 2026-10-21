# Getting started

By the end of this page one Omarchy laptop starts without asking for a disk passphrase, and you hold its recovery key.
Try it on a spare laptop or a virtual machine first.

## 1. Check the laptop

- **Omarchy 4**, installed with disk encryption (the default), on a laptop that starts in UEFI mode.
- **A TPM 2.0**, turned on in the firmware settings (some firmwares call it PTT or fTPM).
- **First-boot setup finished**, if the laptop was installed for a later owner or factory reset.
- **The disk passphrase**: the one chosen at install.

Nothing needs changing in the firmware settings: Secure Boot can stay as the laptop came (usually off).

## 2. Install

On a freshly installed laptop, run `omarchy update` first: until then pacman has no package lists, and can't fetch the
few things this package needs. Then download the `.pkg.tar.zst` file and `SHA256SUMS` from the
[releases page](https://github.com/blatessa/monarchy-encryption/releases), and:

```bash
sha256sum -c --ignore-missing SHA256SUMS
sudo pacman -U monarchy-encryption-*.pkg.tar.zst
```

Installing changes nothing until you run `setup`.

## 3. Set up

```bash
sudo monarchy-encryption setup
```

It asks for the disk passphrase, checks it opens the disk and that the TPM can be tied to this laptop's boot files,
then switches the laptop to the boot environment TPM unlock needs and locks the boot menu. Last, it prints the
laptop's **recovery key**: eight groups of eight letters.

**Store the recovery key now**, in a password manager or your MDM's record for the laptop. It's shown only once and
never written to the laptop.

## 4. Restart

Restart the laptop, soon: until you do, the laptop opens its disk by itself with nothing checked. There's nothing to
type at this start. As the laptop starts, it finishes setting up by itself: it tells the TPM which boot files started,
ties the disk to them, checks the TPM opens it, and removes the disk passphrase.

```bash
sudo monarchy-encryption status
```

`Protected: yes`. From now on the laptop starts without asking for anything, and the login screen is where people sign
in. Updates keep it that way. When the laptop starts something the TPM can't vouch for (a boot file changed outside
the update tools, a cleared TPM), the disk asks for the recovery key: type it there.

## What now

| You want to | Read |
|---|---|
| Set up many laptops from an MDM, with nobody at the keyboard | [Roll out to a fleet](guides/rollout.md) |
| Replace the recovery key, answer the recovery key prompt, factory reset | [Manage laptops](guides/manage.md) |
| Understand what the TPM checks and what it doesn't | [How it works](concepts/how-it-works.md) |
| Know what `setup` or `status` is telling you | [Troubleshooting](guides/troubleshooting.md), [CLI](reference/cli.md) |
