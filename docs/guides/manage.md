# Manage laptops

## When the laptop asks for the recovery key

The disk asks for the recovery key when the TPM won't vouch for what started: a boot file changed outside the update
tools, a snapshot with an older boot image, or a TPM that was cleared. Type the recovery key at the disk prompt, dashes
included.

As the laptop starts, it tells the TPM about the boot files that started, so the next start needs nothing typed. If
it asks again, the TPM no longer holds what it needs (cleared, or the mainboard replaced): once the laptop has
started,

```bash
sudo monarchy-encryption setup     # give it the recovery key
```

ties the disk to the TPM again.

## Replace the recovery key

```bash
sudo monarchy-encryption recovery-key            # prints the new key
sudo monarchy-encryption recovery-key --json     # {"schema":1,"recovery_key":"…","previous_key":"removed"}
```

Store the new key: the old one stops working. Once the TPM unlocks the disk, nothing needs to be typed. Replace it
after it has been read out to someone over the phone, for example.

## Updates

Nothing to do. Kernel, Limine and Omarchy updates keep the laptop protected: the TPM is told about the new boot files
as they're built, and a pacman hook puts back anything an update undid. `omarchy-refresh-limine` is fine too. To check:

```bash
sudo monarchy-encryption status
```

## Give a laptop back, or factory reset it

```bash
sudo monarchy-encryption release     # asks for a new disk passphrase
```

`release` undoes `setup`: the disk unlocks with the new passphrase again, and the TPM no longer opens it. The disk stays
encrypted. An MDM gives the new passphrase on standard input; if the TPM no longer opens the disk (a cleared TPM, say),
it also needs the recovery key, as a second line.

To **factory reset** a laptop, run `release` first, then Omarchy's reset (`omarchy-system-factory-reset`), which asks
for the passphrase you just set (`setup` removed the old one). After
the reset and its first-boot setup, `setup` takes the laptop back.
