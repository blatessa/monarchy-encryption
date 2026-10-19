# Manage laptops

## When the laptop asks for the recovery key

The disk asks for the recovery key when the TPM won't vouch for the laptop: Secure Boot was turned off, its keys were
changed, or the firmware was updated. Type the recovery key at the disk prompt, dashes included. Then, once the laptop
has started:

```bash
sudo monarchy-encryption setup     # give it the recovery key
```

`setup` ties the disk to the TPM again for the laptop as it is now, and the next start needs nothing typed.

If Secure Boot was turned off, turn it back on in the firmware settings first.

## Replace the recovery key

```bash
sudo monarchy-encryption recovery-key            # prints the new key
sudo monarchy-encryption recovery-key --json     # {"schema":1,"recovery_key":"…","previous_key":"removed"}
```

Store the new key: the old one stops working. Once the TPM unlocks the disk, nothing needs to be typed. Replace it
after it has been read out to someone over the phone, for example.

## Updates

Nothing to do. Kernel, Limine and Omarchy updates keep the laptop protected: they're signed as they're built, and a
pacman hook puts back anything an update undid. `omarchy-refresh-limine` is fine too. To check:

```bash
sudo monarchy-encryption status
```

## Give a laptop back, or factory reset it

```bash
sudo monarchy-encryption release     # asks for a new disk passphrase
```

`release` undoes `setup`: the disk unlocks with the new passphrase again, the TPM no longer opens it, and the firmware's
Secure Boot keys are handed back (Secure Boot is off from the next start). The disk stays encrypted. An MDM gives the new
passphrase on standard input; if the TPM no longer opens the disk (after a firmware update, say), it also needs the
recovery key, as a second line.

To **factory reset** a laptop, run `release` first, then Omarchy's reset (`omarchy-system-factory-reset`), which asks
for the passphrase you just set. Without `release`, the reset leaves boot files the firmware refuses to start. After
the reset and its first-boot setup, `setup` takes the laptop back.
